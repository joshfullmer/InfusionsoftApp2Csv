require 'fields_arrays.rb'
require 'infusionsoft_actions.rb'

class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
end
