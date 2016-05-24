#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'
require 'tempfile'
require 'gpgme'
require 'yaml'
require 'docker'
require 'socket'
require 'timeout'
require 'resolv'
require 'open3'
require 'net/http'
require_relative 'lib/options'
require_relative 'lib/file_helpers'

class SystemCalls

  def execute_docker_compose(environment, cmd, args = [])
    puts "- Executing 'docker-compose' -f '#{environment.get_docker_compose_file}' with command '#{cmd}' and args '#{args}'"
    Kernel.abort('Error running docker-compose') unless Kernel.system *['docker-compose', '-f', "#{environment.get_docker_compose_file}", '-f', "#{environment.get_testing_docker_compose_file}", cmd.to_s, *args]
  end

  def execute_docker(cmd, *args)
    puts "- Executing 'docker' with command '#{cmd}' and args #{args}"
    Kernel.abort('Error running docker') unless Kernel.system 'docker', cmd.to_s, *args
  end

  def kill_current_environment(environment)
    puts "- Attempting to stop all running Docker containers for environment '#{environment.environment_name}'..."

    begin
      Docker::Network.get("#{environment.get_compose_project_name}_default")
      execute_docker_compose(environment,:down)
      puts '- Stopped current Docker environment.'
    rescue
      puts "- No containers for Docker environment '#{environment.environment_name}' are running."
    end
  end
end

#
# Decrypts the vault and then binds all parameters contained within as environment parameters.
#
def decrypt_vault_and_modify_env
  begin
    puts 'Decrypting vault and binding environment parameters...'
    crypto = GPGME::Crypto.new
    fname = File.open '../_config/secrets.yaml.gpg'

    secrets = YAML.load(crypto.decrypt(fname).to_s)

    secrets.each do |k, v|
      ENV[k] = v
      puts " - Bound environment variable '#{k}' from decrypted vault"
    end
    puts 'Succesfully decrypted vault and bound environment parameters.'
  rescue GPGME::Error => e
    abort "Unable to decrypt vault (#{e})"
  end
end

def block_wait_drupal_started(environment, supporting_services)

  if check_supported_service_requested(supporting_services, 'drupal')

    drupal_container = get_docker_container(environment, 'drupal_1')

    puts 'Waiting to proceed until Drupal is up'
    docker_host = determine_docker_host_for_container_ports
    drupal_port80_info = drupal_container.json['NetworkSettings']['Ports']['80/tcp'].first
    drupal_port = drupal_port80_info['HostPort']

    # Add the drupal cdn prefix
    ENV['cdn_prefix'] = 'sites/default/files'

    puts "Testing drupal access via #{docker_host}:#{drupal_port}"
    up = false
    until up do
      begin
        response = Net::HTTP.get_response(URI("http://#{docker_host}:#{drupal_port}/user/login"))
        response_code = response.code.to_i
        up = response_code < 400
      rescue
        up = false
      end
    end

    # Add this to the ENV so we can pass it to the awestruct build and also to templating of environment resources
    ENV['DRUPAL_HOST_IP'] = docker_host
    ENV['DRUPAL_HOST_PORT'] = drupal_port
  else
    puts "Not waiting for Drupal to start as it is not a required supporting_service"
  end
end

#
# Gets the JSON for a the given container in the given environment
#
def get_docker_container(environment, container_name)

  container_id = "#{environment.get_compose_project_name}_#{container_name}"
  container = Docker::Container.get(container_id)

  until container.json['NetworkSettings']['Ports']
    puts "Finding port info for Docker container '#{container_id}'..."
    container = Docker::Container.get(container_id)
  end

  container
end

def check_supported_service_requested(supporting_services, service_name)
  !supporting_services.nil? and supporting_services.include?(service_name)
end

def block_wait_searchisko_started(environment, supporting_services)

  if check_supported_service_requested(supporting_services, 'searchisko')

    searchisko_container = get_docker_container(environment, 'searchisko_1')

    puts 'Waiting to proceed until searchisko is up'

    docker_host = determine_docker_host_for_container_ports
    searchisko_port8080_info = searchisko_container.json['NetworkSettings']['Ports']['8080/tcp'].first
    searchisko_port = searchisko_port8080_info['HostPort']

    puts "Testing searchisko access via #{docker_host}:#{searchisko_port}"
    up = false
    until up do

      begin
        response = Net::HTTP.get_response(URI("http://#{docker_host}:#{searchisko_port}/v2/rest/search/events"))
        response_code = response.code.to_i
        up = response_code < 400
      rescue
        up = false
      end
    end
    ENV['SEARCHISKO_HOST_IP'] = docker_host
    ENV['SEARCHISKO_HOST_PORT'] = searchisko_port
  else
    puts "Not waiting for Searchisko to start as it is not a required supporting_service"
  end

end

#
# Tries to load the environment specified or aborts if the environment does not exist
#
def load_environment(tasks)
  environment = tasks[:environment]
  if environment.nil?
    Kernel.abort("Unable to load details of environment '#{tasks[:environment_name]}'")
  end
  environment
end

#
# Copies the project root Gemfile and Gemfile.lock into the _docker/awestruct
# directory if they have changed since the last run of this script. This ensures
# that when the Awestruct image is built, it always contains the most up-to-date
# project dependencies.
#
def copy_project_dependencies_for_awestruct_image

  puts "- Copying project dependencies into '_docker/awestruct' for build..."

  parent_gemfile = File.open '../Gemfile'
  parent_gemlock = File.open '../Gemfile.lock'

  target_gemfile = FileHelpers.open_or_new('awestruct/Gemfile')
  target_gemlock = FileHelpers.open_or_new('awestruct/Gemfile.lock')
  #Only copy if the file has changed. Otherwise docker won't cache optimally
  FileHelpers.copy_if_changed(parent_gemfile, target_gemfile)
  FileHelpers.copy_if_changed(parent_gemlock, target_gemlock)

  puts "- Successfully copied project dependencies into '_docker/awestruct' for build."

end

#
# Delegates out to Gulp to build the CSS and JS for Drupal
#
def build_css_and_js_for_drupal
  puts '- Building CSS and JS for Drupal...'

  out, status = Open3.capture2e('$(npm bin)/gulp')
  Kernel.abort("Error building CSS / JS for Drupal: #{out}") unless status.success?

  puts '- Successfully built CSS and JS for Drupal'
end

#
# Builds the developers.redhat.com base Docker images
#
def build_base_docker_images(system_exec)
  system_exec.execute_docker(:build, '--tag=developer.redhat.com/base', './base')
  system_exec.execute_docker(:build, '--tag=developer.redhat.com/java', './java')
  system_exec.execute_docker(:build, '--tag=developer.redhat.com/ruby', './ruby')
end

#
# Builds the Docker images for the environment we're running in
#
def build_environment_docker_images(environment, system_exec)
  system_exec.execute_docker_compose(environment, :build)
end

#
# Builds all of the environment resources including Docker images and any CSS/JS in the case of Drupal
#
def build_environment_resources(environment, system_exec)
  puts "Building all required resources for environment '#{environment.environment_name}'"

  if environment.is_drupal_environment?
    build_css_and_js_for_drupal
  end

  copy_project_dependencies_for_awestruct_image
  build_base_docker_images(system_exec)
  build_environment_docker_images(environment, system_exec)

end

#
# This works around using docker-machine in non-native docker environments e.g. on a Mac.
# In that scenario, host-mapped container ports are *not* mapped to localhost, instead they are mapped
# to the VM provisioned by docker-machine.
#
# Users are expected to set a host alias of 'docker' for the VM that is running their docker containers. If
# this alias does not exist, then we have to assume that Docker is running directly on the local machine.
#
# Note: We cannot rely on 'docker inspect' to determine this as it reports the host IP as 0.0.0.0 in a
# docker-machine environment, presumably because that makes sense in the context of the docker-machine install.
#
def determine_docker_host_for_container_ports

  docker_host = Resolv.getaddress(Socket.gethostname)

  begin
    docker_host = Resolv.getaddress('docker')
    puts "Host alias for 'docker' found. Assuming container ports are exposed on ip '#{docker_host}'"
  rescue
    puts "No host alias for 'docker' found. Assuming container ports are exposed on '#{docker_host}'"
  end

  docker_host

end

#
# Starts any required supporting services (if any), and then waits for them to be
# reported as up before continuing
#
def start_and_wait_for_supporting_services(environment, supporting_services, system_exec)

  unless supporting_services.nil? or supporting_services.empty?
    puts "Starting all required supporting services..."

    environment.create_template_resources
    system_exec.execute_docker_compose(environment, :up, %w(-d --no-recreate).concat(supporting_services))
    block_wait_searchisko_started(environment, supporting_services)
    block_wait_drupal_started(environment, supporting_services)
    environment.template_resources

    puts "Started all required supporting services."
  end
end

#
# This guard allows the functions within this script to be unit tested without actually executing the script
#
if $0 == __FILE__

  system_exec = SystemCalls.new
  tasks = Options.parse ARGV
  environment = load_environment(tasks)

  #the docker url is taken from DOCKER_HOST env variable otherwise
  Docker.url = tasks[:docker] if tasks[:docker]

  if tasks[:kill_all]
    system_exec.kill_current_environment(environment)
  end

  if tasks[:decrypt]
    decrypt_vault_and_modify_env
  end

  if tasks[:build]
    build_environment_resources(environment, system_exec)
  end

  if tasks[:unit_tests]
    system_exec.execute_docker_compose(environment, :run, tasks[:unit_tests])
  end

  start_and_wait_for_supporting_services(environment, tasks[:supporting_services], system_exec)

  if tasks[:awestruct_command_args]
    system_exec.execute_docker_compose(environment, :run, tasks[:awestruct_command_args])
  end

  if tasks[:scale_grid]
    system_exec.execute_docker_compose(environment,:scale, tasks[:scale_grid])
  end

  if tasks[:acceptance_test_target_task]
    system_exec.execute_docker_compose(environment,:run, tasks[:acceptance_test_target_task])
  end
end