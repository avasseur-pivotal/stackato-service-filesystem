# Copyright (c) 2009-2011 VMware, Inc.
$:.unshift File.join(File.dirname(__FILE__), ".")

require "base/provisioner"
require "filesystem_service/common"
require "filesystem_service/error"
require "uuidtools"
require "vcap/sysadm"
require "doozer"

class VCAP::Services::Filesystem::Provisioner < VCAP::Services::Base::Provisioner

  include VCAP::Services::Filesystem::Common
  include VCAP::Services::Filesystem

  config_base_dir = ENV["CLOUD_FOUNDRY_CONFIG_PATH"] || File.join(File.dirname(__FILE__), '..', 'config')
  FILESYSTEM_CONFIG_FILE = File.join(config_base_dir, 'filesystem_gateway.yml')

  def initialize(options)
    super(options)
  end

  # Only check instances orphans, there is no binding orphan of filesystem service
  def check_orphan(handles, &blk)
    @logger.debug("[#{service_description}] Check if there are orphans")
    reset_orphan_stat
    @handles_for_check_orphan = handles.deep_dup
    instances_list = []
    Dir.foreach("/var/vcap/services/filesystem/storage") do |child|
      unless child == "." || child ==".."
        child.gsub! "filesystem-", ""
        instances_list << child if File.directory?(File.join("/var/vcap/services/filesystem/storage", child))
      end
    end
    nid = "gateway"
    instances_list.each do |ins|
      @staging_orphan_instances[nid] ||= []
      @staging_orphan_instances[nid] << ins unless @handles_for_check_orphan.index { |h| h["service_id"] == ins }
    end
    oi_count = @staging_orphan_instances.values.reduce(0) { |m, v| m += v.count }
    @logger.debug("Staging Orphans: Instances: #{oi_count}")
    blk.call(success)
  rescue => e
    @logger.warn(e)
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def purge_orphan(orphan_ins_hash, orphan_bind_hash, &blk)
    # TODO: just log it now, since remove the direcotory is a dangerous operation.
    if orphan_ins_hash["gateway"] && !orphan_ins_hash["gateway"].empty?
      orphan_ins_hash["gateway"].each do |ins|
        @logger.warn("Instance #{ins} is an orphan")
      end
    else
      @logger.info("No orphons")
    end
    blk.call(success)
  rescue => e
    @logger.warn(e)
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def prov_svcs_count
    count = 0
    @prov_svcs.each do |k, prov|
      next if prov[:configuration] && prov[:configuration]["data"] && prov[:configuration]["data"]["binding_options"]
      count += 1
    end

    count
  end

  def provision_service(request, prov_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to provision instance (request=#{request.extract})")
    name = UUIDTools::UUID.random_create.to_s

    per_fs   = fs_config[:max_fs_size] # in MB
    total_fs = fs_config[:available_storage]

    if (total_fs - prov_svcs_count * per_fs) < per_fs
      @logger.warn("Insufficient space, requesting #{per_fs}MB, have #{@prov_svcs} provisioned services")
      raise FilesystemError.new(FilesystemError::FILESYSTEM_INSUFFICIENT_SPACE)
    end

    limit = per_fs

    instance = SA::create_filesystem_instance(limit)
    # instance = {
    #   "instance_id" => 'u3h5ui245i24g5oi24g5',
    #   "dir"         => '/var/vcap/services/filesystem/storage/filesystem-u3h5...',
    #   "private_key" => '-----BEGIN RSA PRIVATE KEY...',
    # }
    raise FilesystemError.new(FilesystemError::FILESYSTEM_CREATE_INSTANCE_DIR_FAILED, name) if instance == nil

    prov_req = ProvisionRequest.new
    prov_req.plan = request.plan
    # use old credentials to provision a service if provided.
    prov_req.credentials = prov_handle["credentials"] if prov_handle

    credentials = {
      "private_key" => instance["private_key"],
      "user"        => instance["user"],
      "dir"         => instance["dir"],
      "host"	    => fs_config[:host],
    }

    svc = {
      :data => prov_req.dup,
      :service_id => instance["instance_id"],
      :credentials => credentials
    }

    # FIXME: workaround for inconsistant representation of bind handle and provision handle
    svc_local = {
      :configuration => prov_req.dup,
      :service_id => name,
      :credentials => credentials
    }
    @logger.debug("Successfully provisioned service for request #{svc.inspect}")
    @prov_svcs[svc[:service_id]] = svc_local
    blk.call(success(svc))
  rescue => e
    if e.instance_of? FilesystemError
      blk.call(failure(e))
    else
      @logger.warn(e)
      blk.call(internal_fail)
    end
  end

  def unprovision_service(instance_id, &blk)
    @logger.debug("[#{service_description}] Attempting to unprovision instance (instance id=#{instance_id}")
    svc = @prov_svcs[instance_id]
    raise FilesystemError.new(FilesystemError::FILESYSTEM_FIND_INSTANCE_FAILED, instance_id) if svc == nil

    SA::cleanup_filesystem_instance(instance_id)
    @prov_svcs.delete(instance_id)
    bindings = find_all_bindings(instance_id)
    bindings.each do |b|
      @prov_svcs.delete(b[:service_id])
    end
    blk.call(success())
  rescue => e
    if e.instance_of? FilesystemError
      blk.call(failure(e))
    else
      @logger.warn(e)
      blk.call(internal_fail)
    end
  end

  def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to bind to service #{instance_id}")
    svc = @prov_svcs[instance_id]
    raise FilesystemError.new(FilesystemError::FILESYSTEM_FIND_INSTANCE_FAILED, instance_id) if svc == nil

    #FIXME options = {} currently, should parse it in future.
    request = BindRequest.new
    request.name = instance_id
    request.bind_opts = binding_options
    service_id = nil
    if bind_handle
      request.credentials = bind_handle["credentials"]
      service_id = bind_handle["service_id"]
    else
      service_id = UUIDTools::UUID.random_create.to_s
    end

    # Save binding-options in :data section of configuration
    config = svc[:configuration].clone
    config['data'] ||= {}
    config['data']['binding_options'] = binding_options
    res = {
      :service_id => service_id,
      :configuration => config,
      :credentials => svc[:credentials]
    }
    @logger.debug("[#{service_description}] Binded: #{res.inspect}")
    @prov_svcs[res[:service_id]] = res
    blk.call(success(res))
  rescue => e
    if e.instance_of? FilesystemError
      blk.call(failure(e))
    else
      @logger.warn(e)
      blk.call(internal_fail)
    end
  end

  def unbind_instance(instance_id, handle_id, binding_options, &blk)
    @logger.debug("[#{service_description}] Attempting to unbind to service #{instance_id}")
    blk.call(success())
  end

  def fs_config
    config, config_rev = Doozer.fake_config_file_load(FILESYSTEM_CONFIG_FILE)
    config = VCAP.symbolize_keys(config)
    config
  end
end
