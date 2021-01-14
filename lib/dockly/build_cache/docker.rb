class Dockly::BuildCache::Docker < Dockly::BuildCache::Base
  attr_accessor :image

  def execute!
    ensure_present! :image
    super
    image
  end

  def run_build
    status, _, container = run_command(build_command)
    raise "Build Cache `#{build_command}` failed to run." unless status.zero?
    cache = copy_output_dir(container)
    debug "pushing #{output_directory} to s3"
    push_to_s3(cache)
    debug "pushed #{output_directory} to s3"
    cache.close
    debug "commiting the completed container with id: #{container.id}"
    image = self.image = container.commit
    debug "created image with id: #{image.id}"
    image
  end

  def push_cache(version)
    ensure_present! :output_dir
    if cache = pull_from_s3(version)
      debug "inserting to #{output_directory}"
      if safe_push_cache
        push_cache_safe(cache)
      else
        push_cache_with_volumes(cache)
      end
      debug "inserted cache into #{output_directory}"
      cache.close
    else
      info "could not find #{s3_object(version)}"
    end
  end

  def push_cache_safe(cache)
    container = image.run("mkdir -p #{File.dirname(output_directory)}")
    image_with_dir = container.tap(&:wait).commit
    self.image = image_with_dir.insert_local(
      'localPath' => cache.path,
      'outputPath' => File.dirname(output_directory)
    )
  end

  def push_cache_with_volumes(cache)
    path = File.expand_path(cache.path)
    path_parent = File.dirname(path)
    tar_flags = keep_old_files ? '-xkf' : 'xf'
    container = ::Docker::Container.create(
      'Image' => image.id,
      'Cmd' => ['/bin/bash', '-c', [
          "mkdir -p #{File.dirname(output_directory)}",
          '&&',
          "tar #{tar_flags} #{File.join('/', 'host', path)} -C #{File.dirname(output_directory)}"
        ].join(' ')
      ],
      'Volumes' => {
        File.join('/', 'host', path_parent) => { path_parent => 'rw' }
      }
    )
    container.start('Binds' => ["#{path_parent}:#{File.join('/', 'host', path_parent)}"])
    result = container.wait['StatusCode']
    raise "Got bad status code when copying build cache: #{result}" unless result.zero?
    self.image = container.commit
  end

  def copy_output_dir(container)
    ensure_present! :output_dir
    file_path = File.join(tmp_dir,s3_object(hash_output))
    FileUtils.mkdir_p(File.dirname(file_path))
    file = File.open(file_path, 'w+b')
    container.wait(3600) # 1 hour max timeout
    debug 'Restarting the container to copy the cache\'s output'
    # Restart the container so we can copy its output
    container = container.commit.run('sleep 3600')
    container.archive_out(output_directory) { |chunk| file.write(chunk.to_s) }
    container.kill
    file.tap(&:rewind)
  end

  def hash_output
    ensure_present! :image, :hash_command
    @hash_output ||= begin
      status, body, _ = run_command(hash_command)
      raise "Hash Command `#{hash_command}` failed to run" unless status.zero?
      body
    end
  end

  def parameter_output(command)
    ensure_present! :image
    raise "Parameter Command tried to run but not found" unless parameter_commands.keys.include?(command)
    @parameter_commands[command] ||= begin
      status, body, _ = run_command(command)
      raise "Parameter Command `#{command}` failed to run" unless status.zero?
      body
    end
  end

  def run_command(command)
    debug "running command `#{command}` on image #{image.id}"
    container = image.run(["/bin/bash", "-c", "cd #{command_directory} && #{command}"])
    debug "command running in container #{container.id}"
    status = container.wait(docker.timeout)['StatusCode']
    resp = container.streaming_logs(stdout: true, stderr: true)
    debug "`#{command}` returned the following output:"
    debug resp.strip
    debug "`#{command}` exited with status #{status}, resulting container id: #{container.id}"
    [status, resp.strip, container]
  end
end
