require 'capistrano_colors'
require 'rvm/capistrano'
require 'bundler/capistrano'

def abort_red(msg)
  abort "  * \e[#{1};31mERROR: #{msg}\e[0m"
end

Capistrano::Configuration.instance.load do

  # required variables
  _cset(:user)                  { abort_red "Please configure your Uberspace user in config/deploy.rb using 'set :user, <username>'" }
  _cset(:repository)            { abort_red "Please configure your code repository config/deploy.rb using 'set :repository, <repo uri>'" }


  # optional variables
  _cset(:domain)                { nil }
  _cset(:passenger_port)        { rand(61000-32768+1)+32768 } # random ephemeral port

  _cset(:deploy_via)            { :remote_cache }
  _cset(:git_enable_submodules) { 1 }
  _cset(:branch)                { 'master' }

  _cset(:keep_releases)         { 3 }

  _cset(:db_pool)               { 5 }

  # uberspace presets
  set(:deploy_to)               { "/var/www/virtual/#{user}/rails/#{application}" }
  set(:home)                    { "/home/#{user}" }
  set(:use_sudo)                { false }
  set(:rvm_type)                { :user }
  set(:rvm_install_ruby)        { :install }
  set(:rvm_ruby_string)         { "ree@rails-#{application}" }

  ssh_options[:forward_agent] = true
  default_run_options[:pty]   = true

  # callbacks
  before  'deploy:setup',           'rvm:install_rvm'
  before  'deploy:setup',           'rvm:install_ruby'
  after   'deploy:setup',           'uberspace:setup_svscan'
  after   'deploy:setup',           'daemontools:setup_daemon'
  after   'deploy:setup',           'apache:setup_reverse_proxy'
  before  'deploy:finalize_update', 'deploy:symlink_shared'
  after   'deploy',                 'deploy:cleanup'

  # custom recipes
  namespace :uberspace do
    task :setup_svscan do
      run 'uberspace-setup-svscan ; echo 0'
    end
  end

  namespace :daemontools do
    task :setup_daemon do
      daemon_script = <<-EOF
#!/bin/bash
export HOME=#{fetch :home}
source $HOME/.bash_profile
cd #{fetch :deploy_to}/current
rvm use #{fetch :rvm_ruby_string}
exec bundle exec passenger start -p #{fetch :passenger_port} -e production 2>&1
      EOF

      log_script = <<-EOF
#!/bin/sh
exec multilog t ./main
      EOF

      run                 "mkdir -p #{fetch :home}/etc/run-rails-#{fetch :application}"
      run                 "mkdir -p #{fetch :home}/etc/run-rails-#{fetch :application}/log"
      put daemon_script,  "#{fetch :home}/etc/run-rails-#{fetch :application}/run"
      put log_script,     "#{fetch :home}/etc/run-rails-#{fetch :application}/log/run"
      run                 "chmod +x #{fetch :home}/etc/run-rails-#{fetch :application}/run"
      run                 "chmod +x #{fetch :home}/etc/run-rails-#{fetch :application}/log/run"
      run                 "ln -nfs #{fetch :home}/etc/run-rails-#{fetch :application} #{fetch :home}/service/rails-#{fetch :application}"

    end
  end

  namespace :apache do
    task :setup_reverse_proxy do
      htaccess = <<-EOF
RewriteEngine On
RewriteRule ^(.*)$ http://localhost:#{fetch :passenger_port}/$1 [P]
      EOF
      path = fetch(:domain) ? "/var/www/virtual/#{fetch :user}/#{fetch :domain}" : "#{fetch :home}/html"
      run                 "mkdir -p #{path}"
      put htaccess,       "#{path}/.htaccess"
      run                 "chmod +r #{path}/.htaccess"
    end
  end

  namespace :deploy do
    task :start do
      run "svc -u #{fetch :home}/service/rails-#{fetch :application}"
    end
    task :stop do
      run "svc -d #{fetch :home}/service/rails-#{fetch :application}"
    end
    task :restart do
      run "svc -du #{fetch :home}/service/rails-#{fetch :application}"
    end

    task :symlink_shared do
      run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
    end
  end

  def string_to_b(string) # to boolean
    case string.downcase
    when 'no', 'false' then false
    when 'yes', 'true' then true
    else
      if block_given? && !!(b = yield(string)) == b # is a boolean
        b
      else
        raise("Cannot convert #{string.inspect} to boolean.")
      end
    end
  end

  def time_pathsafe
    Time.now.strftime("%Y%m%d%H%M%S")
  end

  def to_past_filename(file)
    ext = File.extname file
    base = File.basename file, ext
    dir = File.dirname file
    "#{dir}/#{base}#{time_pathsafe}#{ext}"
  end

  namespace :db do
    task :dump do
      root_dir = [deploy_to, current_dir].join('/')

      remote_dump_env  = ENV['REMOTE_DUMP_ENV']
      remote_dump_file = ENV['REMOTE_DUMP_FILE'] || [root_dir, 'db', 'data.yml'].join('/')
      remote_rails_env = ENV['RAILS_ENV'] || 'production'

      local_load_env = ENV['LOAD_ENV']
      local_rails_env = 'development'
      load_to_db = string_to_b(ENV['LOAD'] || 'false') do |s|
        if ['development', 'production', 'test'].include? s
          local_rails_env = s
          true
        end
      end
      local_destination = ENV['DUMP_FILE'] || "db/data.#{time_pathsafe}.yml"
      backup_local = string_to_b(ENV['BACKUP'] || 'true')
      keep_remote_dump = string_to_b(ENV['KEEP_REMOTE_DUMP'] || 'false')

      dump_script = <<-EOF
        cd #{root_dir}
        [ -f #{remote_dump_file} ] && mv #{remote_dump_file} #{to_past_filename(remote_dump_file)}
        bundle exec rake db:data:dump RAILS_ENV=#{remote_rails_env} #{remote_dump_env} 
      EOF
      dump_script = dump_script.lines.map(&:strip).join("; ")
      run(dump_script)
      data = capture("cat #{remote_dump_file}")
      run("rm #{remote_dump_file}") unless keep_remote_dump
      if backup_local && File.file?(local_destination)
        File.rename local_destination, to_past_filename(local_destination)
      end

      File.write(local_destination, data)

      run_locally("bundle exec rake db:data:load RAILS_ENV=#{local_rails_env} #{local_load_env}") if load_to_db
    end
  end

  namespace :files do
    desc 'Downloads the public/uploaded files in a zip (default is "public/system")'
    task :dump do
      root_dir = [deploy_to, current_dir].join('/')
      data_folder = ENV['DATA_DIR'] || 'public/system'
      via = (ENV['VIA'] || 'scp').downcase.to_sym
      local_path = ["files", time_pathsafe].join(".")
      path = [root_dir, data_folder].join("/")
      download(path, local_path, via: via, recursive: true)
    end
  end
end