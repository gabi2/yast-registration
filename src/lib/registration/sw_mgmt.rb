# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#
#

require "yast"

require "tmpdir"
require "fileutils"

require "registration/exceptions"
require "registration/helpers"
require "registration/url_helpers"
require "registration/repo_state"

module Registration
  Yast.import "AddOnProduct"
  Yast.import "Mode"
  Yast.import "Stage"
  Yast.import "Pkg"
  Yast.import "Report"
  Yast.import "PackageLock"
  Yast.import "Installation"
  Yast.import "PackageCallbacks"

  class SwMgmt
    include Yast
    include Yast::Logger
    extend Yast::I18n

    textdomain "registration"

    ZYPP_DIR = "/etc/zypp"

    FAKE_BASE_PRODUCT = { "name" => "SLES", "arch" => "x86_64", "version" => "12",
      "release_type" => "DVD" }

    def self.init
      # false = do not allow continuing without the libzypp lock
      lock = PackageLock.Connect(false)
      return false unless lock["connected"]

      # display progress when refreshing repositories
      PackageCallbacks.InitPackageCallbacks
      Pkg.TargetInitialize(Installation.destdir)
      Pkg.TargetLoad
      Pkg.SourceRestore
    end

    # during installation /etc/zypp directory is not writable (mounted on
    # a read-only file system), the workaround is to copy the whole directory
    # structure into a writable temporary directory and override the original
    # location by "mount -o bind"
    def self.zypp_config_writable!
      return if !(Mode.installation || Mode.update) || File.writable?(ZYPP_DIR)

      log.info "Copying libzypp config to a writable place"

      # create writable zypp directory structure in /tmp
      tmpdir = Dir.mktmpdir

      log.info "Copying #{ZYPP_DIR} to #{tmpdir} ..."
      ::FileUtils.cp_r ZYPP_DIR, tmpdir

      log.info "Mounting #{tmpdir} to #{ZYPP_DIR}"
      `mount -o bind #{tmpdir}/zypp #{ZYPP_DIR}`
    end

    def self.find_base_product
      # just for debugging:
      return FAKE_BASE_PRODUCT if ENV["FAKE_BASE_PRODUCT"]

      # during installation the products are :selected,
      # on a running system the products are :installed
      # during upgrade use the newer selected product (same as in installation)
      products = Pkg.ResolvableProperties("", :product, "").find_all do |p|
        if Stage.initial
          # during installation the type is not valid yet yet
          # (the base product is determined by /etc/products.d/baseproduct symlink)
          # the base product comes from the first repository
          p["source"] == 0
        else
          # in installed system the base product has valid type
          p["status"] == :installed && p["type"] == "base"
        end
      end

      log.debug "Found base products: #{products}"
      log.info "Found base products: #{products.map { |p| p["name"] }}"
      log.warn "More than one base product found!" if products.size > 1

      products.first
    end

    def self.installed_products
      # just for testing/debugging
      return [FAKE_BASE_PRODUCT] if ENV["FAKE_BASE_PRODUCT"]

      products = Pkg.ResolvableProperties("", :product, "").select do |p|
        p["status"] == :installed
      end

      log.info "Found installed products: #{products.map { |p| p["name"] }}"
      products
    end

    # convert a libzypp Product Hash to a SUSE::Connect::Remote::Product object
    # @param product [Hash] product Hash obtained from pkg-bindings
    # @return [SUSE::Connect::Remote::Product] the remote product
    def self.remote_product(product)
      SUSE::Connect::Remote::Product.new(
        arch:         product["arch"],
        identifier:   product["name"],
        version:      product["version"],
        release_type: product["release_type"]
      )
    end

    # create UI label for a base product
    # @param base_product [Hash] Product (hash from pkg-bindings)
    # @return [String] UI Label
    def self.base_product_label(base_product)
      base_product["display_name"] ||
        base_product["short_name"] ||
        base_product["name"] ||
        _("Unknown product")
    end

    def self.base_product_to_register
      # just for debugging:
      return FAKE_BASE_PRODUCT if ENV["FAKE_BASE_PRODUCT"]

      base_product = find_base_product

      # filter out not needed data
      product_info = {
        "name"         => base_product["name"],
        "arch"         => base_product["arch"],
        "version"      => ::Registration::Helpers.base_version(base_product["version"]),
        "release_type" => base_product["flavor"]
      }

      log.info("Base product to register: #{product_info}")

      product_info
    end

    # add the services to libzypp and load (refresh) them
    def self.add_service(product_service, credentials)
      # save repositories before refreshing added services (otherwise
      # pkg-bindings will treat them as removed by the service refresh and
      # unload them)
      if !Pkg.SourceSaveAll
        # error message
        raise ::Registration::PkgError, N_("Saving repository configuration failed.")
      end

      # services for registered products
      log.info "Adding service #{product_service.name.inspect} (#{product_service.url})"

      credentials_file = UrlHelpers.credentials_from_url(product_service.url)

      if credentials_file
        if Mode.update
          # at update libzypp is already switched to /mnt target,
          # update the path accordingly
          credentials_file = File.join(Installation.destdir,
            ::SUSE::Connect::Credentials::DEFAULT_CREDENTIALS_DIR,
            credentials_file)
          log.info "Using #{credentials_file} credentials path in update mode"
        end
        # SCC uses the same credentials for all services, just save them to
        # a different file
        service_credentials = credentials.dup
        service_credentials.file = credentials_file
        service_credentials.write
      end

      service_name = product_service.name

      # add a new service or update the existing service
      if Pkg.ServiceAliases.include?(service_name)
        log.info "Updating existing service: #{service_name}"
        if !Pkg.ServiceSet(service_name,
          "alias"       => service_name,
          "name"        => service_name,
          "url"         => product_service.url.to_s,
          "enabled"     => true,
          "autorefresh" => true
          )

          ## error message
          raise ::Registration::ServiceError.new(N_("Updating service '%s' failed."), service_name)
        end
      else
        log.info "Adding new service: #{service_name}"
        if !Pkg.ServiceAdd(service_name, product_service.url.to_s)
          # error message
          raise ::Registration::ServiceError.new(N_("Adding service '%s' failed."), service_name)
        end

        if !Pkg.ServiceSet(service_name, "autorefresh" => true)
          # error message
          raise ::Registration::ServiceError.new(N_("Updating service '%s' failed."), service_name)
        end
      end

      # refresh works only for saved services
      if !Pkg.ServiceSave(service_name)
        # error message
        raise ::Registration::ServiceError.new(N_("Saving service '%s' failed."), service_name)
      end

      if !Pkg.ServiceRefresh(service_name)
        # error message
        raise ::Registration::ServiceError.new(N_("Refreshing service '%s' failed."), service_name)
      end
    ensure
      Pkg.SourceSaveAll
    end

    # remove a libzypp service and save the repository configuration
    # @param [String] name name of the service to remove
    def self.remove_service(name)
      log.info "Removing service #{name}"

      if Pkg.ServiceDelete(name) && !Pkg.SourceSaveAll
        # error message
        raise ::Registration::PkgError, N_("Saving repository configuration failed.")
      end
    end

    # get list of repositories belonging to registered services
    # @param product_service [SUSE::Connect::Remote::Service] added service
    # @param only_updates [Boolean] return only update repositories
    # @return [Array<Hash>] list of repositories
    def self.service_repos(product_service, only_updates: false)
      repo_data = Pkg.SourceGetCurrent(false).map { |repo| repository_data(repo) }

      service_name = product_service.name
      log.info "Service name: #{service_name.inspect}"

      # select only repositories belonging to the product services
      repos = repo_data.select { |repo| service_name == repo["service"] }
      log.info "Service repositories: #{repos}"

      if only_updates
        # leave only update repositories
        repos.select! { |repo| repo["is_update_repo"] }
        log.info "Found update repositories: #{repos}"
      end

      repos
    end

    # get repository data
    # @param [Fixnum] repo repository ID
    # @return [Hash] repository properties, including the repository ID ("SrcId" key)
    def self.repository_data(repo)
      data = Pkg.SourceGeneralData(repo)
      data["SrcId"] = repo
      data
    end

    # Set repository state (enabled/disabled)
    # The original repository state is saved to RepoStateStorage to restore
    # the original state later.
    # @param repos [Array<Hash>] list of repositories
    # @param enabled [Boolean] true = enable, false = disable, nil = no change
    # @return [void]
    def self.set_repos_state(repos, enabled)
      # keep the defaults when not defined
      return if enabled.nil?

      repos.each do |repo|
        next if repo["enabled"] == enabled

        # remember the original state
        repo_state = RepoState.new(repo["SrcId"], repo["enabled"])
        RepoStateStorage.instance.repositories << repo_state

        log.info "Changing repository state: #{repo["name"]} enabled: #{enabled}"
        Pkg.SourceSetEnabled(repo["SrcId"], enabled)
      end
    end

    # copy old NCC/SCC credentials from the old installation to new SCC credentials
    # the files are copied to the current system
    def self.copy_old_credentials(source_dir)
      log.info "Searching registration credentials in #{source_dir}..."

      # ensure the zypp directory is writable in inst-sys
      zypp_config_writable!

      dir = SUSE::Connect::Credentials::DEFAULT_CREDENTIALS_DIR
      # create the target directory if missing
      if !File.exist?(dir)
        log.info "Creating directory #{dir}"
        ::FileUtils.mkdir_p(dir)
      end

      # check for NCC credentials
      ncc_file = File.join(source_dir, dir, "NCCcredentials")
      copy_old_credentials_file(ncc_file)

      scc_file = File.join(source_dir, SUSE::Connect::Credentials::GLOBAL_CREDENTIALS_FILE)
      copy_old_credentials_file(scc_file)
    end

    def self.copy_old_credentials_file(file)
      return unless File.exist?(file)

      new_file = SUSE::Connect::Credentials::GLOBAL_CREDENTIALS_FILE
      log.info "Copying the old credentials from previous installation"
      log.info "Copying #{file} to #{new_file}"
      ::FileUtils.cp(file, new_file)

      credentials = SUSE::Connect::Credentials.read(new_file)
      # note: SUSE::Connect::Credentials override #to_s, the password is filtered out
      log.info "Using previous credentials: #{credentials}"
    end

    private_class_method :copy_old_credentials_file

    def self.find_addon_updates(addons)
      log.info "Available addons: #{addons.map(&:identifier)}"

      products = Pkg.ResolvableProperties("", :product, "")

      installed_addons = products.select do |product|
        product["status"] == :installed && product["type"] != "base"
      end

      product_names = installed_addons.map { |a| "#{a["name"]}-#{a["version"]}-#{a["release"]}" }
      log.info "Installed addons: #{product_names}"

      ret = addons.select do |addon|
        installed_addons.any? do |installed_addon|
          addon.updates_addon?(installed_addon)
        end
      end

      log.info "Found addons to update: #{ret.map(&:identifier)}"
      ret
    end

    # update the static defaults in AddOnProduct module
    def self.update_product_renames(renames)
      renames.each do |old_name, new_name|
        AddOnProduct.add_rename(old_name, new_name)
      end
    end

    # a helper method for iterating over repositories
    # @param repo_aliases [Array<String>] list of repository aliases
    # @param block block evaluated for each found repository
    def self.each_repo(repo_aliases, &block)
      all_repos = Pkg.SourceGetCurrent(false)

      repo_aliases.each do |repo_alias|
        # find the repository with the alias
        repository = all_repos.find do |repo|
          Pkg.SourceGeneralData(repo)["alias"] == repo_alias
        end

        if repository
          block.call(repository)
        else
          log.warn "Repository '#{repo_alias}' was not found, skipping"
        end
      end
    end

    # select products for new added extensions/modules
    # @return [Boolean] true on success
    def self.select_addon_products
      addon_services = ::Registration::Storage::Cache.instance.addon_services
      log.info "New addon services: #{addon_services}"

      new_repos = addon_services.reduce([]) do |acc, service|
        acc.concat(::Registration::SwMgmt.service_repos(service))
      end

      return true if new_repos.empty?

      products = Pkg.ResolvableProperties("", :product, "")
      products.select! do |product|
        product["status"] == :available &&
          new_repos.any? { |new_repo| product["source"] == new_repo["SrcId"] }
      end
      products.map! { |product| product["name"] }

      log.info "Products to install: #{products}"

      products.all? { |product| Pkg.ResolvableInstall(product, :product) }
    end

    # select remote addons matching the product resolvables
    def self.select_product_addons(products, addons)
      addons.each do |addon|
        log.info "Found remote addon: #{addon.identifier}-#{addon.version}-#{addon.arch}"
      end

      # select a remote addon for each product
      products.each do |product|
        remote_addon = addons.find do |addon|
          product["name"] == addon.identifier &&
            product["version_version"] == addon.version &&
            product["arch"] == addon.arch
        end

        if remote_addon
          remote_addon.selected
        else
          product_label = "#{product["display_name"]} (#{product["name"]}" \
            "-#{product["version_version"]}-#{product["arch"]})"

          # TRANSLATORS: %s is a product name
          Report.Error(_("Cannot find remote product %s.\n" \
                "The product cannot be registered.") % product_label
          )
        end
      end
    end

    # find the product resolvables from the specified repository
    def self.products_from_repo(repo_id)
      # TODO: only installed products??
      Pkg.ResolvableProperties("", :product, "").select do |product|
        product["source"] == repo_id
      end
    end

    private_class_method :each_repo
  end
end
