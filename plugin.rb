# name: discourse-theme-creator
# about: Allows users to create and share their own themes.
# version: 0.1
# author: David Taylor dtaylor.uk
# url: https://www.github.com/davidtaylorhq/discourse-theme-creator

register_asset "stylesheets/theme-creator.scss"

load File.expand_path('../lib/theme_creator/engine.rb', __FILE__)

after_initialize do

  # We're re-using a lot of locale strings from the admin section
  # so we need to load it for non-staff users.
  register_html_builder('server:before-head-close') do |ctx|
    "<script src='#{ExtraLocalesController.url('admin')}'></script>" +
    ctx.helpers.preload_script('admin')
  end

  # Override guardian to allow users to preview their own themes using the ?preview_theme_key= variable
  add_to_class(:guardian, :allow_theme?) do |theme_key|
    return true if Theme.user_theme_keys.include?(theme_key) # Is a 'user selectable theme'
    return false if not Theme.theme_keys.include?(theme_key) # Is not a valid theme

    # If you own the theme, you are allowed to view it using GET param
    # Even staff are not allowed to use GET to access other user's themes, to reduce XSS attack risk
    can_hotlink_user_theme? Theme.find_by(key: theme_key)
  end

  add_to_class(:guardian, :can_hotlink_user_theme?) do |theme|
    is_my_own?(theme)
  end

  add_to_class(:guardian, :can_see_user_theme?) do |theme|
    return true if is_staff?

    return true if is_my_own?(theme)

    # Theme is shared and theme owner has permission to share
    theme.is_shared && User.find(theme.user_id).guardian.can_share_user_theme?(theme)
  end

  add_to_class(:guardian, :can_edit_user_theme?) do |theme|
    is_staff? || is_my_own?(theme)
  end

  add_to_class(:guardian, :can_share_user_theme?) do |theme|
    return true if SiteSetting.theme_creator_share_groups.blank? # all users can share

    # Check if user is in any allowed groups
    allowed_groups = SiteSetting.theme_creator_share_groups.split("|")
    @user.groups.where(name: allowed_groups).exists?
  end

  # Add methods so that a theme can be shared/unshared by the user
  add_to_class(:theme, :is_shared) do
    !!share_slug
  end

  add_to_class(:theme, :share_slug) do
    @share_slug ||= PluginStore.get('discourse-theme-creator', "share:#{user_id}:#{id}")
  end

  add_to_class(:theme, :share_slug=) do |val|
    if !val
      @share_slug = nil
      PluginStore.remove('discourse-theme-creator', "share:#{user_id}:#{id}")
      return
    end

    val = val.downcase
    valid = (/^[a-z0-9_-]+$/ =~ val)
    return false if !valid

    unique = !PluginStoreRow.where(plugin_name: 'discourse-theme-creator')
      .where("key LIKE ?", "share:#{user_id}:%")
      .where(value: val)
      .any?
    return false if !unique

    @share_slug = val
    PluginStore.set('discourse-theme-creator', "share:#{user_id}:#{id}", val)
  end

  # We block hotlinking of other users themes.
  # If an admin wants to see another users theme, redirect them to the share UI.
  add_to_class(::Admin::ThemesController, :preview) do
    @theme ||= Theme.find(params[:id])

    can_hotlink = guardian.can_hotlink_user_theme?(@theme)
    can_view = guardian.can_see_user_theme?(@theme)

    if !can_hotlink && can_view
      redirect_to path("/theme/#{@theme.key}")
    else
      raise Discourse::InvalidAccess.new() if !can_hotlink
      redirect_to path("/?preview_theme_key=#{@theme.key}")
    end
  end

  add_to_serializer(:theme, :is_shared) do
    object.is_shared
  end

  add_to_serializer(:theme, :share_slug) do
    object.share_slug
  end

  add_to_serializer(:theme, :base_share_url) do
    UrlHelper.absolute_without_cdn("/theme/#{object.user.username}/")
  end

  add_to_serializer(:theme, :can_share) do
    User.find(object.user_id).guardian.can_share_user_theme?(object)
  end

  reloadable_patch do |plugin|
    class ::Theme
      belongs_to :user
    end
  end

  # Allow preview of shared user themes
  # flash[:user_theme_key] will only be populated after a POST request
  # after a UI confirmation (theme_creator_controller.rb) to prevent hotlinking
  reloadable_patch do |plugin|
    class ::ApplicationController
      module ThemeCreatorOverrides
        def handle_theme
          super()
          user_theme_key = flash[:user_theme_key]
          if user_theme_key &&
             Theme.theme_keys.include?(user_theme_key) && # Has requested a valid theme
             guardian.can_see_user_theme?(Theme.find_by(key: user_theme_key))
            @theme_key = request.env[:resolved_theme_key] = user_theme_key
          end
        end
      end
      prepend ThemeCreatorOverrides
    end
  end

  reloadable_patch do |plugin|
    UserApiKey::SCOPES[:user_themes] = [[:post, 'theme_creator/theme_creator#import'], [:put, 'theme_creator/theme_creator#update']]
  end

end
