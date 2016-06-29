ModalView = require 'views/core/ModalView'
AuthModal = require 'views/core/AuthModal'
template = require 'templates/core/create-account-modal/basic-info-view'
forms = require 'core/forms'
errors = require 'core/errors'
User = require 'models/User'
State = require 'models/State'

###
This view handles the primary form for user details — name, email, password, etc,
and the AJAX that actually creates the user.

It also handles facebook/g+ login, which if used, open one of two other screens:
sso-already-exists: If the facebook/g+ connection is already associated with a user, they're given a log in button
sso-confirm: If this is a new facebook/g+ connection, ask for a username, then allow creation of a user

The sso-confirm view *inherits from this view* in order to share its account-creation logic and events.
This means the selectors used in these events must work in both templates.

This view currently uses the old form API instead of stateful render.
It needs some work to make error UX and rendering better, but is functional.
###

module.exports = class BasicInfoView extends ModalView
  id: 'basic-info-view'
  template: template

  events:
    'input input[name="email"]': 'onInputEmail'
    'input input[name="name"]': 'onInputName'
    'click .back-button': 'onClickBackButton'
    'submit form': 'onSubmitForm'
    'click .use-suggested-name-link': 'onClickUseSuggestedNameLink'
    'click #facebook-signup-btn': 'onClickSsoSignupButton'
    'click #gplus-signup-btn': 'onClickSsoSignupButton'

  initialize: ({ @sharedState } = {}) ->
    @state = new State {
      suggestedName: null
      emailCheck: 'standby' # 'checking', 'exists', 'available'
      nameCheck: 'standby' # same
    }
    @checkNameExistsDebounced = _.debounce(_.bind(@checkNameExists, @), 500)
    @checkEmailExistsDebounced = _.debounce(_.bind(@checkEmailExists, @), 500)
    @listenTo @state, 'change:emailCheck', -> @renderSelectors('.email-check')
    @listenTo @state, 'change:nameCheck', -> @renderSelectors('.name-check')
    @listenTo @sharedState, 'change:facebookEnabled', -> @renderSelectors('.auth-network-logins')
    @listenTo @sharedState, 'change:gplusEnabled', -> @renderSelectors('.auth-network-logins')
    
  afterRender: ->
    super()
    if suggestedName = @state.get('suggestedName')
      @setNameError(suggestedName)

  onInputEmail: ->
    @state.set('emailCheck', 'standby')
    @checkEmailExistsDebounced()
    
  checkEmailExists: ->
    email = @$('[name="email"]').val()
    return unless email
    @state.set('emailCheck', 'checking')
    User.checkEmailExists(email)
    .then ({exists}) =>
      return unless email is @$('[name="email"]').val()
      if exists
        @state.set('emailCheck', 'exists')
      else
        @state.set('emailCheck', 'available')
    .catch (e) =>
      @state.set('emailCheck', 'standby')
      throw e

  onInputName: ->
    @state.set('nameCheck', 'standby')
    @checkNameExistsDebounced()

  checkNameExists: ->
    name = @$('input[name="name"]').val()
    return unless name
    @state.set('nameCheck', 'checking')
    User.checkNameConflicts(name).then ({ suggestedName, conflicts }) =>
      return unless @$('input[name="name"]').val() is name
      if conflicts
        @state.set({ nameCheck: 'exists', suggestedName })
      else
        @state.set { nameCheck: 'available' }
    .catch (error) ->
      @state.set('nameCheck', 'standby')
      throw error

  checkBasicInfo: (data) ->
    # TODO: Move this to somewhere appropriate
    tv4.addFormat({
      'email': (email) ->
        if forms.validateEmail(email)
          return null
        else
          return {code: tv4.errorCodes.FORMAT_CUSTOM, message: "Please enter a valid email address."}
    })
    
    forms.clearFormAlerts(@$el)
    res = tv4.validateMultiple data, @formSchema()
    forms.applyErrorsToForm(@$('form'), res.errors) unless res.valid
    return res.valid
  
  formSchema: ->
    type: 'object'
    properties:
      email: User.schema.properties.email
      name: User.schema.properties.name
      password: User.schema.properties.password
    required: ['email', 'name', 'password'].concat (if @sharedState.get('path') is 'student' then ['firstName', 'lastName'] else [])
  
  onClickBackButton: -> @trigger 'nav-back'
  
  onClickUseSuggestedNameLink: (e) ->
    @$('input[name="name"]').val(@state.get('suggestedName'))
    forms.clearFormAlerts(@$el.find('input[name="name"]').closest('.form-group').parent())

  onSubmitForm: (e) ->
    e.preventDefault()
    data = forms.formToObject(e.currentTarget)
    valid = @checkBasicInfo(data)
    return unless valid

    @displayFormSubmitting()
    
    User.checkEmailExists(@$('[name="email"]').val())
    
    .then ({ exists }) =>
      if exists
        @state.set('emailCheck', 'exists')
        return @displayFormStandingBy()
        
      return User.checkNameConflicts(name)
    
    .then ({ conflicts }) =>
      if conflicts
        @state.set('nameCheck', 'exists')
        return @displayFormStandingBy()
        
      # update User
      emails = _.assign({}, me.get('emails'))
      emails.generalNews ?= {}
      emails.generalNews.enabled = @$('#subscribe-input').is(':checked')
      me.set('emails', emails)
      
      unless _.isNaN(@sharedState.get('birthday').getTime())
        me.set('birthday', @sharedState.get('birthday')?.toISOString())
      
      me.set(_.without(@sharedState.get('ssoAttrs') or {}, 'email'))
      jqxhr = me.save()
      if not jqxhr
        console.error(me.validationError)
        throw new Error('Could not save user')

      return new Promise(jqxhr.then)
    
    .then =>
      # Use signup method
      window.tracker?.identify()
      switch @sharedState.get('ssoUsed')
        when 'gplus'
          { email, gplusID } = @sharedState.get('ssoAttrs')
          jqxhr = me.signupWithGPlus(email, gplusID)
        when 'facebook'
          { email, facebookID } = @sharedState.get('ssoAttrs')
          jqxhr = me.signupWithFacebook(email, gplusID)
        else
          { email, password } = forms.formToObject(@$el)
          jqxhr = me.signupWithPassword(email, password)

      return new Promise(jqxhr.then)
      
    .then =>
      if @sharedState.get('classCode')
        location.href = "/courses?_cc=#{@sharedState.get('classCode')}"
      else
        window.location.reload()
        
    .catch (e) =>
      console.error 'caught!', e
      throw e
      
  displayFormSubmitting: ->
    @$('#create-account-btn').text($.i18n.t('signup.creating')).attr('disabled', true)
    @$('input').attr('disabled', true)
    
  displayFormStandingBy: ->
    @$('#create-account-btn').text($.i18n.t('signup.create_account')).attr('disabled', false)
    @$('input').attr('disabled', false)

#  createUser: ->
#    options = {}
#    window.tracker?.identify()
#    # TODO: Move to User functions which call specific endpoints for signup
#    if @sharedState.get('ssoUsed') is 'gplus'
#      @newUser.set('_id', me.id)
#      options.url = "/db/user?gplusID=#{@sharedState.get('ssoAttrs').gplusID}&gplusAccessToken=#{application.gplusHandler.accessToken.access_token}"
#      options.type = 'PUT'
#    if @sharedState.get('ssoUsed') is 'facebook'
#      @newUser.set('_id', me.id)
#      options.url = "/db/user?facebookID=#{@sharedState.get('ssoAttrs').facebookID}&facebookAccessToken=#{application.facebookHandler.authResponse.accessToken}"
#      options.type = 'PUT'
#    @newUser.save(null, options)
#    @newUser.once 'sync', @onUserCreated, @
#    @newUser.once 'error', @onUserSaveError, @
#  
#  onUserSaveError: (user, jqxhr) ->
#    # TODO: Do we need to enable/disable the submit button to prevent multiple users being created?
#    # Seems to work okay without that, but mongo had 2 copies of the user... temporarily. Very strange.
#    if _.isObject(jqxhr.responseJSON) and jqxhr.responseJSON.property
#      forms.applyErrorsToForm(@$el, [jqxhr.responseJSON])
#      @setNameError(@state.get('suggestedName'))
#    else
#      console.log "Error:", jqxhr.responseText
#      errors.showNotyNetworkError(jqxhr)
#  
#  onUserCreated: ->
#    # TODO: Move to User functions
#    Backbone.Mediator.publish "auth:signed-up", {}
#    if @sharedState.get('gplusAttrs')
#      window.tracker?.trackEvent 'Google Login', category: "Signup", label: 'GPlus'
#      window.tracker?.trackEvent 'Finished Signup', category: "Signup", label: 'GPlus'
#    else if @sharedState.get('facebookAttrs')
#      window.tracker?.trackEvent 'Facebook Login', category: "Signup", label: 'Facebook'
#      window.tracker?.trackEvent 'Finished Signup', category: "Signup", label: 'Facebook'
#    else
#      window.tracker?.trackEvent 'Finished Signup', category: "Signup", label: 'CodeCombat'
#    if @sharedState.get('classCode')
#      url = "/courses?_cc="+@sharedState.get('classCode')
#      location.href = url
#    else
#      window.location.reload()

  onClickSsoSignupButton: (e) ->
    # TODO: Switch to Promises
    e.preventDefault()
    ssoUsed = $(e.currentTarget).data('sso-used')
    if ssoUsed is 'facebook'
      handler = application.facebookHandler
      fetchSsoUser = 'fetchFacebookUser'
      idName = 'facebookID'
    else
      handler = application.gplusHandler
      fetchSsoUser = 'fetchGPlusUser'
      idName = 'gplusID'
    handler.connect({
      context: @
      success: ->
        handler.loadPerson({
          context: @
          success: (ssoAttrs) ->
            @sharedState.set { ssoAttrs }
            existingUser = new User()
            existingUser[fetchSsoUser](@sharedState.get('ssoAttrs')[idName], {
              context: @
              success: =>
                @sharedState.set {
                  ssoUsed
                  email: ssoAttrs.email
                }
                @trigger 'sso-connect:already-in-use'
              error: (user, jqxhr) =>
                @sharedState.set {
                  ssoUsed
                  email: ssoAttrs.email
                }
                @trigger 'sso-connect:new-user'
            })
        })
    })
