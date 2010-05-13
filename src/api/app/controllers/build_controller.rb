class BuildController < ApplicationController

  def project_index
    @path = request.path
    unless request.query_string.empty?
      @path += '?' + request.query_string
    end

    if request.get?
      pass_to_backend @path
    elsif request.post?
      allowed = false
      allowed = true if permissions.global_project_change

      if not allowed
        prj = DbProject.find_by_name( params[:project] ) 
        if prj.nil?
          render_error :status => 403, :errorcode => "not_found",
            :message => "Project does not exist #{params[:project]}"
          return
        end

        #check if user has project modify rights
        allowed = true if permissions.project_change? prj
      end

      if not allowed and not params[:package].nil?
        package_names = nil
        if params[:package].kind_of? Array
          package_names = params[:packge]
        else
          package_names = [params[:package]]
        end

        package_names.each do |pack_name|
          pkg = DbPackage.find_by_project_and_name( prj, pack_name ) 
          if pkg.nil?
            render_error :status => 404, :errorcode => "not_found",
              :message => "Package does not exist #{pack_name}"
            return
          end
          allowed = permissions.package_change? pkg
          if not allowed
            render_error :status => 403, :errorcode => "execute_cmd_no_permission",
              :message => "No permission to execute command on package #{pack_name}"
            return
          end
        end
      end

      if not allowed
        render_error :status => 403, :errorcode => "execute_cmd_no_permission",
          :message => "No permission to execute command on project #{params[:project]}"
        return
      end

      #check for cmd parameter
      if params[:cmd].nil?
        render_error :status => 403, :errorcode => "missing_parameter",
          :message => "Missing parameter 'cmd'"
        return
      end

      pass_to_backend @path
      return
    else
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: #{request.method.to_s.upcase} #{request.path}"
      return
    end
  end

  def buildinfo
    valid_http_methods :get, :post
    path = "/build/#{params[:project]}/#{params[:repository]}/#{params[:arch]}/#{params[:package]}/_buildinfo"
    unless request.query_string.empty?
      path += '?' + request.query_string
    end

    pass_to_backend path
  end

  # /build/:prj/:repo/:arch/:pkg
  # GET on ?view=cpio and ?view=cache unauthenticated and streamed
  def package_index
    valid_http_methods :get
    pass_to_backend
  end

  # /build/:project/:repository/:arch/:package/:filename
  def file
    valid_http_methods :get
    pkg = DbPackage.find_by_project_and_name params[:project], params[:package]
    if pkg and
        (pkg.binarydownload_flags.disabled_for?(params[:repository], params[:arch]) or
         pkg.protectall_flags.disabled_for?(params[:repository], params[:arch])) and not
        @http_user.can_protectall_downloadbinany?(pkg)
      render_error :status => 403, :errorcode => "download_binary_no_permission",
      :message => "No permission to download binaries from package #{params[:package]}, project #{params[:project]}"
      return
    end

    path = request.path+"?"+request.query_string

    regexp = nil
    # if there is a query, we can't assume it's a simple download, so better leave out the logic (e.g. view=fileinfo)
    unless request.query_string
      #check if binary exists and for size
      fpath = "/build/"+[:project,:repository,:arch,:package].map {|x| params[x]}.join("/")
      file_list = Suse::Backend.get(fpath)
      regexp = file_list.body.match(/name=["']#{Regexp.quote params[:filename]}["'].*size=["']([^"']*)["']/)
    end
    if regexp
      fsize = regexp[1]
      logger.info "streaming #{path}"

      c_type = case params[:filename].split(/\./)[-1]
               when "rpm"
                 "application/x-rpm"
               when "deb"
                 "application/x-deb"
               when "iso"
                 "application/x-cd-image"
               else
                 "application/octet-stream"
               end

      headers.update(
        'Content-Disposition' => %(attachment; filename="#{params[:filename]}"),
        'Content-Type' => c_type,
        'Transfer-Encoding' => 'binary',
        'Content-Length' => fsize
      )
      
      render :status => 200, :text => Proc.new {|request,output|
        backend_request = Net::HTTP::Get.new(path)
        Net::HTTP.start(SOURCE_HOST,SOURCE_PORT) do |http|
          http.request(backend_request) do |response|
            response.read_body do |chunk|
              output.write(chunk)
            end
          end
        end
      }
    else
      pass_to_backend path
    end
  end

  def logfile
    valid_http_methods :get
    pkg = DbPackage.find_by_project_and_name params[:project], params[:package]
    #logfile controled by binarydownload_flags and download_binary permission
    if pkg and pkg.binarydownload_flags.disabled_for?(params[:repository], params[:arch]) and not @http_user.can_download_binaries?(pkg)
      render_error :status => 403, :errorcode => "download_binary_no_permission",
      :message => "No permission to download logfile for package #{params[:package]}, project #{params[:project]}"
      return
    end
    pass_to_backend
  end

  def result
    valid_http_methods :get
    prj = DbProject.find_by_name params[:project]
    pkg = prj.find_package params[:package]
    if prj and
        prj.privacy_flags.disabled_for?(params[:repository], params[:arch]) and
        prj.protectall_flags.disabled_for?(params[:repository], params[:arch]) and not
        @http_user.can_protectall_viewany?(prj)
#     render_error :status => 403, :errorcode => "private_view_no_permission",
#     :message => "No permission to view project #{params[:project]}"
      render_ok
      return
    end
    if pkg and pkg.privacy_flags.disabled_for?(params[:repository], params[:arch]) and not @http_user.can_private_view?(pkg)
      render_ok
      return
    end
    pass_to_backend
  end

end
