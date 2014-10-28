require 'yaml'
require 'json'
require 'xmlsimple'

class Wsman
  BIOS_SVC_CLASS = "DCIM_BIOSService"
  RAID_SVC_CLASS = "DCIM_RAIDService"
  JOB_SVC_CLASS = "DCIM_JOBService"
  LC_SVC_CLASS = "DCIM_LCService"
  SOFT_SVC_CLASS = "DCIM_SoftwareInstallationService"

  BASE_URI = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2"
  URI_NS = "#{BASE_URI}/root/dcim"

  SOFT_IDEN_URI = "#{URI_NS}/DCIM_SoftwareIdentity"
  SOFT_SVC_URI = "#{URI_NS}/DCIM_SoftwareInstallationService"
  SYS_VIEW_URI = "#{URI_NS}/DCIM_SystemView"
  BIOS_ENUM_URI = "#{URI_NS}/DCIM_BIOSEnumeration"

  CHANGE_BOOT_ORDER_CMD = "ChangeBootOrderByInstanceID"
  CHANGE_BOOT_STATE_CMD = "ChangeBootSourceState"

  RETURN_CFG_OK = 0
  RETURN_VAL_OK = '0'
  RETURN_CONFIG_VAL_OK = 4096
  RETURN_CFG_JOB = 4096
  RETURN_VAL_FAIL = '2'
  RETURN_VAL_NO_ACTION = '-1'

  ENUMERATE_CMD = 'enumerate'

  attr :host
  attr :user
  attr :password
  attr :port
  attr :debug_time

  def initialize(opts = {})
    @host = opts[:host]
    @user = opts[:user]
    @password = opts[:password]
    @port = opts[:port] || 443
    @debug_time = opts[:debug_time] || false
    @debug = opts[:debug] || false
  end

  def self.certname(host)
    "/tmp/cer-#{host}.cer"
  end

  def self.setup_env(host, user, password)
    filename = self.class.certname(host)
    return true if File.exists?(filename)

    output = %x{ping -W 3 -c 2 #{host} 2>/dev/null >/dev/null}

    if $?.exitstatus != 0
      puts "Failed to ping host: #{host}"
      return false
    end

    output = %x{echo | openssl s_client -connect #{host}:443 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >#{filename} 2>&1}

    if $?.exitstatus != 0
      puts output
      return false
    end

    true
  end

  def measure_time(msg)
    start = Time.now if @debug_time
    yield
    puts "#{msg}: #{Time.now - start}" if @debug_time
  end

  def setup_env
    retVal  = self.class.setup_env(@host, @user, @password)
    return retVal
  end

  def command(action, url, args = "", count = 0)
    retVal = self.setup_env

    if !retVal
      puts "Unable to ping system...exiting"
      return false
    end

    filename = self.class.certname(@host)
    output = ""
    ret = 0
    stdargs = "-N root/dcim -v -V -o -j utf-8 -y basic"

    self.measure_time "WSMAN #{action} #{url} call" do
      cmd = "wsman #{action} #{url} -h #{@host} -P #{@port} -u #{@user} -p #{@password} -c #{filename} #{stdargs} #{args} 2>&1"
      output = %x{#{cmd}}
      ret = $?.exitstatus
    end

    if ret != 0
      puts "wsman command failed: #{action}"
      puts output

      return false
    end

    if output =~ /Connection failed. response code = 0/
      return false if count >= 3

      puts "Retrying the command: #{count} #{action}"
      sleep 20

      return command(action, url, args, count + 1)
    end

    return output
  end

  def schedule_job(jid, time)
    job_svc_uri = find_instance_uri(JOB_SVC_CLASS)
    output = self.command("invoke -a SetupJobQueue",job_svc_uri, " -k JobArray=\"#{jid}\" -k StartTimeInterval=\"#{time}\"")

    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]

    if t["Fault"]
      return false, t["Fault"]
    end

    if t["SetupJobQueue_OUTPUT"]["ReturnValue"].instance_of? Hash
      return true, "nil value"
    end

    if t["SetupJobQueue_OUTPUT"]["ReturnValue"] != "0"
      return false, t["SetupJobQueue_OUTPUT"]["Message"]
    end

    return true, 0
  end

  def clear_all_jobs
    job_svc_uri = find_instance_uri(JOB_SVC_CLASS)
    output = self.command("invoke -a DeleteJobQueue",job_svc_uri, " -m 256 -k JobID=\"JID_CLEARALL\"")

    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]

    if t["Fault"]
      return false, t["Fault"]
    end

    if t["DeleteJobQueue_OUTPUT"]["ReturnValue"].instance_of? Hash
      return true, "nil value"
    end

    ret = t["DeleteJobQueue_OUTPUT"]["ReturnValue"].to_i == 0 rescue false
    return ret, t["DeleteJobQueue_OUTPUT"]["Message"]
  end

  def get_job_status(jid)
    output = self.command("get","#{URI_NS}/DCIM_LifecycleJob?InstanceID=#{jid}")
    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]
    if t["Fault"]
      return false, t["Fault"]["Reason"]["Text"]["content"]
    end

    js = t["DCIM_LifecycleJob"]["JobStatus"]
    if js == "New"
      if t["DCIM_LifecycleJob"]["MessageID"] == "RED023"
        return false, "In Use"
      end
    end

    return true, js
  end

  def is_RS_ready?
    lc_svc_uri = find_instance_uri(LC_SVC_CLASS)
    output = self.command("invoke -a GetRSStatus", lc_svc_uri)

    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]

    if t["Fault"]
      return false, t["Fault"]
    end

    if t["GetRSStatus_OUTPUT"]["ReturnValue"].instance_of? Hash
      return true, "Ready"
    end

    if t["GetRSStatus_OUTPUT"]["ReturnValue"] != "0"
      return false, t["GetRSStatus_OUTPUT"]["Message"]
    end

    status = t["GetRSStatus_OUTPUT"]["Status"]
    puts "Status from getrsstatus is #{status}"

    return status == "Ready", status
  end

  def find_instance_uri(serviceClass)
    url = "#{URI_NS}/#{serviceClass}"
    xml = self.command("enumerate", url, " -m 512 -M epr")
    selectorStr = "#{url}?"
    content = self.process_response(xml,'["Body"]["EnumerateResponse"]["Items"]')

    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]

      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "#{url}?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end

    selectorStr
  end

  def find_base_instance_uri(serviceClass)
    url = "#{BASE_URI}/#{serviceClass}"
    xml = self.command(ENUMERATE_CMD, url, " -m 512 -M epr")
    selectorStr = "#{url}?"
    content = self.process_response(xml,'["Body"]["EnumerateResponse"]["Items"]')

    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]

      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "#{url}?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end

    selectorStr
  end

  def find_instance_uri_from_objepr(content)
    selectorStr = "?"

    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]

      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end

    selectorStr
  end

  def get_selector_string(instHash)
    selectorStr = ""
    selectorSet = instHash["EndpointReference"]["ReferenceParameters"]["SelectorSet"]

    if selectorSet["Selector"].is_a?(Array)
      selectorSet["Selector"].each do |selector|
        if (!selector.nil?)
          selectorStr += %Q[<w:Selector Name="#{selector["Name"]}">#{selector["content"]}</w:Selector>] unless selector["Name"] == "__cimnamespace"
        end
      end
    elsif selectorSet["Selector"].is_a?(Hash)
      selectorStr += %Q[<w:Selector Name="#{selectorSet["Selector"]["Name"]}">#{selectorSet["Selector"]["content"]}</w:Selector>]
    end

    puts "selector string is #{selectorStr}"
    selectorStr
  end

  def get_job_id(instHash)
    jobID = ""
    selectorSet = ""
    testFor12G = instHash["EndpointReference"]

    if testFor12G.nil?
      selectorSet = instHash["ReferenceParameters"]["SelectorSet"]
    else
      selectorSet = instHash["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
    end

    if selectorSet["Selector"].is_a?(Array)
      selectorSet["Selector"].each do |selector|
        if !selector.nil?
          jobID = selector["content"] if selector["Name"] != "__cimnamespace"
        end
      end
    elsif selectorSet["Selector"].is_a?(Hash)
      jobID = selectorSet["Selector"]["content"]
    end

    puts "parsed job id string is #{jobID}"
    jobID
  end

  def get_job_selector(instHash)
    puts "Parsing job selector string"

    selectorStr = instHash["ReferenceParameters"]["ResourceURI"] + "?"
    selectorSet = instHash["ReferenceParameters"]["SelectorSet"]

    selectorSet["Selector"].each do |selector|
      selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
    end

    selectorStr
  end

  def power_down_system
    retVal = false
    method = "RequestStateChange"

    xml = self.command(ENUMERATE_CMD, CS_INST_URI, " -m 512 -M objepr")
    instanceList = self.process_response(xml,'["Body"]["EnumerateResponse"]["Items"]["Item"]')
    instanceList = (instanceList.instance_of?(Array)) ? instanceList : [instanceList]

    instanceList.each do |instance|
      if instance.is_a?(Hash)
        classNames = instance.keys
        classNames.delete("EndpointReference")

        if (instance[classNames[0]]['Dedicated']).to_i == 0
          newcsinst = "#{URI_NS}/#{classNames[0]}"
          csuri = newcsinst + find_instance_uri_from_objepr(instance)

          xml = self.command("#{INVOKE_CMD} -a #{method} -k RequestedState='3'", csuri)
          returnVal = self.current_value(xml,method)

          if returnVal.to_i == RETURN_CFG_OK
            retVal = true
          end
        end
      end
    end

    retVal
  end

  def create_update_reboot_job
    retVal = false
    jobID = ""

    puts "Creating reboot job for updates..."

    method = "CreateRebootJob"
    inputFile = "/tmp/#{method}.xml"

    File.open(inputFile, "w+") do |ff|
      ff.write %Q[
        <p:#{method}_INPUT xmlns:p="#{URI_NS}/DCIM_SoftwareInstallationService">
          <p:RebootJobType>3</p:RebootJobType>
        </p:#{method}_INPUT>
      ]
    end

    cmd = "#{INVOKE_CMD} -a #{method}"
    instURI = find_instance_uri(SOFT_SVC_CLASS)
    output = self.command(cmd, instURI , "-J #{inputFile}")

    puts "Debug: create reboot job failed no output" unless output
    return [ false, "Failed to create update job" ] unless output

    retVal = self.current_value(output,method)

    if retVal.to_i == RETURN_CFG_OK
      puts "No RID returned...invocation of downgrade failed"
    elsif retVal.to_i == RETURN_CFG_JOB
      wsInstance = self.process_response(output, '["Body"]["CreateRebootJob_OUTPUT"]["RebootJobID"]')
      jobID = get_job_id(wsInstance)
      retVal = true
    else
      puts "Error encountered in job creation..."
    end

    [retVal, jobID]
  end

  def create_reboot_job
    retVal = false
    jobID = ""

    puts "Creating reboot job for stacking in job queue..."

    method = "CreateRebootJob"
    cmd  = "#{INVOKE_CMD} -a #{method}"
    instURI = find_instance_uri(JOB_SVC_CLASS)
    output = self.command(cmd, instURI , "-k RebootJobType=3")

    puts "Debug: create reboot job failed no output" unless output
    return [ false, "Failed to create update job" ] unless output

    retVal = self.current_value(output,method)

    if retVal.to_i == RETURN_CFG_OK
      puts "No RID returned...invocation of createrebootjob failed"
    elsif retVal.to_i == RETURN_CFG_JOB
      wsInstance = self.process_response(output, '["Body"]["CreateRebootJob_OUTPUT"]["Job"]')
      jobID = get_job_id(wsInstance)
      retVal = true
    else
      puts "Error encountered in job creation..."
    end

    [retVal, jobID]
  end

  def setup_job_queue_multi(jobArray)
    retVal = false
    jobStr = ""
    method = "SetupJobQueue"

    if jobArray.nil?
      puts "Input job array is nil...exiting"
    else
      inputFile = "/tmp/#{method}.xml"

      File.open("#{inputFile}", "w+") do |ff|
        ff.write %Q[<p:#{method}_INPUT xmlns:p="#{URI_NS}/#{JOB_SVC_CLASS}">]

        jobArray.each do |jobID|
          ff.write %Q[<p:JobArray>#{jobID}</p:JobArray>]
        end

        ff.write %Q[<p:StartTimeInterval>TIME_NOW</p:StartTimeInterval>]
        ff.write %Q[</p:#{method}_INPUT>]
      end

      cmd = "#{INVOKE_CMD} -a #{method}"
      svcUri = find_instance_uri(JOB_SVC_CLASS)
      output = self.command(cmd, svcUri, "-J #{inputFile}")

      puts output

      returnVal = self.current_value(output,method)

      if returnVal.to_i == RETURN_CFG_OK
        puts "Successfully set up job queue"
        retVal = true
      end
    end

    retVal
  end

  def create_targeted_config_job(svc_class_uri, fqdd)
    puts "Creating targeted config job..."

    cmd = "#{INVOKE_CMD} -a CreateTargetedConfigJob -k Target=#{fqdd} -k ScheduledStartTime=TIME_NOW -k RebootJobType=1"
    output = self.command(cmd, svc_class_uri)
    returnVal = self.current_value(output, "CreateTargetedConfigJob")

    if returnVal.to_i == RETURN_CFG_JOB
      puts "Successfully created a config job..."

      wsInstance = self.process_response(output,'["Body"]["CreateTargetedConfigJob_OUTPUT"]["Job"]')
      jobURI = get_job_selector(wsInstance)

      if jobURI.nil?
        puts "Unable to parse JID for targeted config job on #{fqdd}...Exiting"
      else
        poll_job_for_completion(jobURI)
      end
    end
  end

  def poll_multiple_jobs(jobArray)
    while jobArray.length != 0
      jobArray.each do |jobID|
        puts "Polling job id #{jobID}"

        jobURI = "#{URI_NS}/DCIM_LifecycleJob?InstanceID=#{jobID}"
        output = self.command("get", jobURI)
        jobStatus = self.process_response(output,'["Body"]["DCIM_LifecycleJob"]["JobStatus"]')

        if jobStatus.downcase =~ /.*completed.*/
          puts "Job #{jobID} completed successfully...."
          jobArray.delete(jobID)
        elsif jobStatus.downcase =~ /fail/
          failReason = self.process_response(output,'["Body"]["DCIM_LifecycleJob"]["Message"]')
          failReasonID = self.process_response(output,'["Body"]["DCIM_LifecycleJob"]["MessageID"]')
          puts "Job failed..#{failReasonID}:#{failReason}"
          jobArray.delete(jobID)
        else
          puts "Job status = #{jobStatus}...Continue to poll"
          sleep(30)
        end
      end
    end
  end

  def poll_job_for_completion(uri)
    puts "Polling config job status... "

    for i in 0..20
      output = self.command("get", uri)
      jobStatus = self.process_response(output, '["Body"]["DCIM_LifecycleJob"]["JobStatus"]')

      if jobStatus.downcase =~ /completed/
        puts "Job completed successfully...."
        break
      elsif jobStatus.downcase =~ /fail/
        failReason = self.process_response(output,'["Body"]["DCIM_LifecycleJob"]["Message"]')
        failReasonID = self.process_response(output,'["Body"]["DCIM_LifecycleJob"]["MessageID"]')

        puts "Job failed..#{failReasonID}:#{failReason}"
        break
      else
        puts "Job status = #{jobStatus}...Continue to poll"
        sleep(30)
      end
    end
  end

  def get_current_and_pending_bootmode
    current_mode = nil
    pending_mode = nil

    begin
      output = self.command(
        ENUMERATE_CMD,
        BIOS_ENUM_URI,
        " -m 512 --dialect \"http://schemas.dmtf.org/wbem/cql/1/dsp0202.pdf\" --filter \"select * from DCIM_BIOSEnumeration where AttributeName='BootMode'\" "
      )

      if output
        wsInstance = self.process_response(output, '["Body"]["EnumerateResponse"]["Items"]')
        current_mode = wsInstance["DCIM_BIOSEnumeration"]["CurrentValue"]
        pending_mode = wsInstance["DCIM_BIOSEnumeration"]["PendingValue"]
      else
        puts "No data returned from enumeration of boot mode attribute"
      end
    rescue Exception => e
      puts "Exception determining boot mode...#{e.message}"
    end

    [current_mode, pending_mode]
  end

  def get_uefi_boot_source_settings
    puts "Determining UEFI boot source settings."

    bss = nil
    uefibss = []

    url = "#{URI_NS}/DCIM_BootSourceSetting"
    xml = self.command(ENUMERATE_CMD, url, "-m 512")

    if xml
      bss = self.process_response(xml, '["Body"]["EnumerateResponse"]["Items"]["DCIM_BootSourceSetting"]')

      if bss
        bss.each do |setting|
          if setting['BootSourceType'] and setting['BootSourceType'] == "UEFI"
            uefibss << setting
          end
        end
      end
    else
      puts "No boot source settings found...Returning empty array of boot source settings"
    end

    uefibss
  end

  def get_bios_boot_source_settings
    puts "Determining BIOS boot source settings."

    bss = nil
    biosbss = []

    url = "#{URI_NS}/DCIM_BootSourceSetting"
    xml = self.command(ENUMERATE_CMD, url, "-m 512")

    if xml
      bss = self.process_response(xml, '["Body"]["EnumerateResponse"]["Items"]["DCIM_BootSourceSetting"]')

      if bss
        bss.each do |setting|
          if setting['BootSourceType'] and (setting['BootSourceType'] == "IPL" or setting['BootSourceType'] == "BCV")
            biosbss << setting
          end
        end
      end
    else
      puts "No boot source settings found...Returning empty array of boot source settings"
    end

    biosbss
  end

  def set_boot_sources(boot_mode, boot_source_settings, nic_first = true)
    puts "Setting boot sources - #{boot_mode}, #{nic_first}"

    boot_source_list = []
    emb_nics = []
    int_nics = []
    all_other_nics = []
    other_boot_srcs = []
    enable_nic_srcs = []

    return boot_source_list if not boot_source_settings or boot_source_settings.length == 0
    return boot_source_list if boot_mode != "UEFI" and boot_mode != "BIOS"

    if nic_first
      boot_source_settings.each do |bss|
        boot_src_instance_id = bss['InstanceID']
        puts "DBG: Processing boot source - #{boot_src_instance_id}"

        emb_nics << boot_src_instance_id if boot_src_instance_id.include?("NIC.Embedded")
        int_nics << boot_src_instance_id if boot_src_instance_id.include?("NIC.Integrated")
        all_other_nics << boot_src_instance_id if boot_src_instance_id.include?("NIC") and !emb_nics.include?(boot_src_instance_id) and !int_nics.include?(boot_src_instance_id)
        other_boot_srcs << boot_src_instance_id if !emb_nics.include?(boot_src_instance_id) and !int_nics.include?(boot_src_instance_id) and !all_other_nics.include?(boot_src_instance_id)

        if boot_src_instance_id and !other_boot_srcs.include?(boot_src_instance_id)
          if boot_mode == "UEFI"
            puts "DBG: Current state of #{boot_src_instance_id} is #{bss['CurrentEnabledStatus'].to_i}"
            enable_nic_srcs << boot_src_instance_id if bss['CurrentEnabledStatus'].to_i == 0
          else
            puts "Not enabling or checking disabled boot sources for BIOS boot mode"
          end
        end
      end

      boot_source_list = emb_nics.sort if emb_nics and emb_nics.length > 0
      boot_source_list = boot_source_list | int_nics.sort if int_nics and int_nics.length > 0
      boot_source_list = boot_source_list | all_other_nics.sort if all_other_nics and all_other_nics.length > 0
      boot_source_list = boot_source_list | other_boot_srcs.sort if other_boot_srcs and other_boot_srcs.length > 0
    else
      puts "nic_first = false. Returning current boot order"
      boot_source_list = boot_source_settings
    end

    puts "DBG: Re-ordered boot source settings list is #{boot_source_list}"
    puts "DBG: Disabled boot source list is #{enable_nic_srcs}"

    [boot_source_list, enable_nic_srcs]
  end

  def writeBootSourceFile(input_file, instance_ids)
    File.open(input_file, "w+") do |f|
      f.write %Q[
        <p:#{CHANGE_BOOT_ORDER_CMD}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BootConfigSetting">
      ]

      instance_ids.each do |instance_id|
        next unless instance_id
        next if instance_id.empty?

        f.write %Q[
          <p:source>#{instance_id}</p:source>
        ]
      end

      f.write %Q[
        </p:#{CHANGE_BOOT_ORDER_CMD}_INPUT>
      ]
    end

    true
  end

  def enable_boot_sources(boot_src_list)
    return_val = false
    flip_state = 1

    if boot_src_list and boot_src_list.length > 0
      return_val = change_boot_source_state(boot_src_list, flip_state)
    else
      puts "DBG: No boot sources to enable"
    end

    return_val
  end

  def change_boot_source_state(boot_src_list, state)
    ret_val = false
    return_val = RETURN_VAL_FAIL

    boot_svc_uri = "#{URI_NS}/DCIM_BootConfigSetting?InstanceID=UEFI"

    cmd = "invoke -a #{CHANGE_BOOT_STATE_CMD}"
    input_file = "/tmp/#{CHANGE_BOOT_STATE_CMD}.xml"
    if boot_src_list and boot_src_list.length > 0
      ret_val = write_enable_boot_src_file(input_file, state, boot_src_list)

      if ret_val
        output = self.command(cmd, boot_svc_uri , "-J #{input_file}")

        if output
          puts "DBG: Output from #{CHANGE_BOOT_STATE_CMD} is #{output}"
          return_val = self.current_value(output, CHANGE_BOOT_STATE_CMD)
        end
      else
        puts "DBG: Failed to create boot source enablement input file"
      end
    else
      puts "DBG: No boot sources to change state on"
    end

    return_val
  end

  def write_enable_boot_src_file(input_file, state, instance_ids)
    File.open(input_file, "w+") do |f|
      f.write %Q[
        <p:#{CHANGE_BOOT_STATE_CMD}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BootConfigSetting">
        <p:EnabledState>#{state}</p:EnabledState>
      ]

      instance_ids.each do |instance_id|
        next unless instance_id
        next if instance_id.empty?

        f.write %Q[
          <p:source>#{instance_id}</p:source>
        ]
      end

      f.write %Q[
        </p:#{CHANGE_BOOT_STATE_CMD}_INPUT>
      ]
    end

    true
  end

  def  process_response(xml, path, options = { "ForceArray" => false })
    hash = XmlSimple.xml_in(xml, options)
    eval("hash#{path}")
  end

  def current_value(xml,cmd)
    path = '["Body"]["' + cmd + '_OUTPUT"]["ReturnValue"]'
    process_response(xml , path)
  end
end
