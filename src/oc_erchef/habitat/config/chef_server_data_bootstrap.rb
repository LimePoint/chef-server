require 'fileutils'
require 'restclient'
require 'json'

class EcPostgres
  # Provides a superuser connection to the specified database
  def self.with_connection(database = 'template1', opts = {})
    require 'pg'
    postgres = {}

{{#if bind.database}}
  {{#eachAlive bind.database.members as |member|}}
    {{#if @last}}
    postgres['vip']="{{member.sys.ip}}"
    postgres['port']="{{member.cfg.port}}"
    postgres['db_superuser_password']="{{member.cfg.superuser_name}}"
    postgres['db_superuser_password']="{{member.cfg.superuser_password}}"
    {{/if}}
  {{/eachAlive}}
{{else}}
    postgres['vip']="{{cfg.postgresql.vip}}"
    postgres['port']="{{cfg.postgresql.port}}"
    postgres['db_superuser_password']="{{cfg.sql_user}}"
    postgres['db_superuser_password']="{{cfg.sql_password}}"
{{/if}}

    connection = nil

    # Some callers expect failure - this gives the option to suppress
    # error logging to avoid confusing output.
    if opts['silent']
      silent = true
      # If a caller specfies silent, it means they anticipate an error to be
      # likely. Don't force over a minute of retries in that case.
      retries = opts['retries'] || 1
    else
      silent = false
      retries = opts['retries'] || 5
    end
    max_retries = retries
    begin
      connection = ::PGconn.open('user' => postgres['db_superuser'],
                                 'host' => postgres['vip'],
                                 'password' => postgres['db_superuser_password'],
                                 'port' => postgres['port'],
                                 'dbname' => database)
    rescue => e
      if retries > 0
        sleep_time = 2**((max_retries - retries))
        retries -= 1
        unless silent
          puts "Error from postgresql: #{e.message.chomp}. Retrying after #{sleep_time}s. Retries remaining: #{retries + 1}"
        end
        sleep sleep_time
        retry
      else
        unless silent
          puts "Error from postgresql: #{e.message.chomp}. Retries have been exhausted."
        end
        raise
      end
    end

    begin
      yield connection
    ensure
      connection.close
    end
  end

  def self.as_user(user)
    # Find the user in the password database.
    u = (user.is_a? Integer) ? Etc.getpwuid(user) : Etc.getpwnam(user)

    old_process_euid = Process.euid
    Process::UID.eid = u.uid
    begin
      yield
    ensure
      Process::UID.eid = old_process_euid
    end
  end
end


class ChefServerDataBootstrap

  GLOBAL_ORG_ID = "00000000000000000000000000000000"
  attr_reader :bifrost, :superuser_authz_id, :bootstrap_time, :server_admins_authz_id

  def initialize
    @bootstrap_time = Time.now.utc.to_s
  end


  def bifrost_superuser_id
      @superuser_id ||= bifrost_superuser_id_from_secrets_file
  end

  def bifrost_superuser_id_from_secrets_file
    secrets = JSON.parse(File.read('{{pkg.svc_config_path}}/veil-secrets.json'))
    secrets['oc_bifrost']['superuser_id']
  end

  def bootstrap
    puts "Boostrapping Chef Server Data"
    # This is done in two steps - we'll first create the bifrost objects and
    # dependencies.  If this fails, it can be re-run idempotently without
    # risk of causing the run to fail.
    @superuser_authz_id = create_actor_in_authz(bifrost_superuser_id)
    users_authz_id = create_container_in_authz(superuser_authz_id)
    orgs_authz_id = create_container_in_authz(superuser_authz_id)
    create_server_admins_global_group_in_bifrost(users_authz_id)

    # put pivotal in server-admins global group
    insert_authz_actor_into_group(server_admins_authz_id, superuser_authz_id)

    # Now that bifrost operations are complete, create the corresponding
    # objects in erchef.  By separating them, we increase the chance that a
    # bootstrap failed due to an error out of bifrost can be recovered
    # by re-running it.
    EcPostgres.with_connection('opscode_chef') do |conn|
      create_superuser_in_erchef(conn)
      create_server_admins_global_group_in_erchef(conn)
      create_global_container_in_erchef(conn, 'organizations', orgs_authz_id)
      create_global_container_in_erchef(conn, 'users', users_authz_id)
    end

    # touch the bootstrapped file
    FileUtils.touch '{{pkg.svc_data_path}}/bootstrapped'
  end

  private

  # Create and set up permissions for the server admins group.
  def create_server_admins_global_group_in_bifrost(users_authz_id)
    @server_admins_authz_id = create_group_in_authz(bifrost_superuser_id)
    %w{create read update delete}.each do |permission|
      # grant server admins group permission on the users container,
      # as the erchef superuser.
      grant_authz_object_permission(permission, "groups", "containers", users_authz_id,
                                    server_admins_authz_id, superuser_authz_id)
      # grant superuser actor permissions on the server admin group,
      # as the bifrost superuser
      grant_authz_object_permission(permission, "actors", "groups", server_admins_authz_id,
                                    superuser_authz_id, bifrost_superuser_id)
    end

    # Grant server-admins read permissions on itself as the bifrost superuser.
    grant_authz_object_permission("read", "groups", "groups", server_admins_authz_id,
                                  server_admins_authz_id, bifrost_superuser_id)
  end

  # Insert the server admins global group into the erchef groups table.
  def create_server_admins_global_group_in_erchef(conn)
    simple_insert(conn, 'groups',
                  id: SecureRandom.uuid.gsub("-", ""),
                  org_id: GLOBAL_ORG_ID,
                  authz_id: server_admins_authz_id,
                  name: 'server-admins',
                  last_updated_by: superuser_authz_id,
                  created_at: bootstrap_time,
                  updated_at: bootstrap_time)
  end

  # insert the erchef superuser's key into the erchef keys table,
  # and the user record into the users table.
  def create_superuser_in_erchef(conn)
    require 'openssl'

    raw_key = OpenSSL::PKey::RSA.new(2048)
    File.write('{{pkg.svc_data_path}}/pivotal.pem', raw_key.to_pem)
    public_key = OpenSSL::PKey::RSA.new(raw_key).public_key.to_s

    user_id = SecureRandom.uuid.gsub("-", "")
    simple_insert(conn, 'keys',
                    id: user_id,
                    key_name: 'default',
                    public_key: public_key,
                    key_version: 0,
                    created_at: bootstrap_time,
                    expires_at: "infinity")

    simple_insert(conn, 'users',
                    id: user_id,
                    username: 'pivotal',
                    email: 'root@localhost.localdomain',
                    authz_id: @superuser_authz_id,
                    created_at: bootstrap_time,
                    updated_at: bootstrap_time,
                    last_updated_by: bifrost_superuser_id,
                    pubkey_version: 0, # Old constrant requires it to be not-null
                    serialized_object: JSON.generate(
                      first_name: "Chef",
                      last_name: "Server",
                      display_name: "Chef Server Superuser"))
  end

  def create_global_container_in_erchef(conn, name, authz_id)
    simple_insert(conn, 'containers',
                    id: authz_id, # TODO is this right?
                    name: name,
                    authz_id: authz_id,
                    org_id: GLOBAL_ORG_ID,
                    last_updated_by: superuser_authz_id,
                    created_at: bootstrap_time,
                    updated_at: bootstrap_time)
  end

  # db helper to construct and execute a simple insert statement
  def simple_insert(conn, table, fields)
    placeholders = []
    1.upto(fields.length) { |x| placeholders << "$#{x}" }
    placeholders.join(", ")
    conn.exec_params("INSERT INTO #{table} (#{fields.keys.join(", ")}) VALUES (#{placeholders.join(", ")})",
                     fields.values) # confirm ordering
  end

  ## Bifrost access helpers.

  def create_group_in_authz(requestor_id)
    create_object_in_authz("groups", requestor_id)
  end

  def create_actor_in_authz(requestor_id)
    create_object_in_authz("actors", requestor_id)
  end

  def create_container_in_authz(requestor_id)
    create_object_in_authz("containers", requestor_id)
  end

  def create_object_in_authz(object_name, requestor_id)
    result = bifrost_request(:post, "#{object_name}", "{}", requestor_id)
    JSON.parse(result)["id"]
  end

  # Tells bifrost that an actor is a member of a group.
  # Group membership is managed through bifrost, and not via erchef.
  def insert_authz_actor_into_group(group_id, actor_id)
    bifrost_request(:put, "/groups/#{group_id}/actors/#{actor_id}", "{}", superuser_authz_id)
  end

  def grant_authz_object_permission(permission_type, granted_to_object_type, granted_on_object_type, granted_on_id, granted_to_id, requestor_id)
    url = "#{granted_on_object_type}/#{granted_on_id}/acl/#{permission_type}"
    body = JSON.parse(bifrost_request(:get, url, nil, requestor_id))
    body[granted_to_object_type] << granted_to_id
    bifrost_request(:put, url, body.to_json, requestor_id)
  end

  # Assemble the appropriate header per bifrost's expectations
  # This automatically retries any failed request.  It is not uncommon
  # for bifrost to be unavailable when we're ready to start, as
  # it's still spinning up.
  #
  def bifrost_request(method, rel_path, body, requestor_id)
    headers = {
      :content_type => :json,
      :accept => :json,
      'X-Ops-Requesting-Actor-Id' => requestor_id
    }
    retries = 5
    begin
      bifrost={}
{{#if bind.oc_bifrost}}
  {{#eachAlive bind.oc_bifrost.members as |member|}}
    {{#if @last}}
       bifrost['vip']="{{member.sys.ip}}"
       bifrost['port']="{{member.cfg.port}}"
    {{/if}}
  {{/eachAlive}}
{{else}}
       bifrost['vip']="{{cfg.oc_bifrost.vip}}"
       bifrost['port']="{{cfg.oc_bifrost.port}}"
{{/if}}
      if method == :get
        RestClient.get("http://#{bifrost['vip']}:#{bifrost['port']}/#{rel_path}", headers)
      else
        RestClient.send(method, "http://#{bifrost['vip']}:#{bifrost['port']}/#{rel_path}",  body, headers)
      end
    rescue RestClient::Exception, Errno::ECONNREFUSED => e
      error = e.respond_to?(:response) ? e.response.chomp : e.message
      if retries > 0
        sleep_time = 2**((5 - retries))
        retries -= 1
        puts "Error from bifrost: #{error}, retrying after #{sleep_time}s. Retries remaining: #{retries}"
        sleep sleep_time
        retry
      else
        puts "Error from bifrost: #{error}, retries have been exhausted"
        raise
      end
    end
  end
end

if File.exist?('{{pkg.svc_data_path}}/bootstrapped')
  puts 'Chef Server Data already bootstrapped - Skipping.'
else
  ChefServerDataBootstrap.new.bootstrap
end
