# frozen_string_literal: true

DiscourseSms::Engine.routes.draw do
  get "/status" => "sms#status"
  get "/users/:username/status" => "sms#user_status"
  post "/send_code" => "sms#send_code"
  post "/verify_code" => "sms#verify_code"
  post "/registration/send_code" => "sms#registration_send_code"
  post "/registration/verify_code" => "sms#registration_verify_code"
end

Discourse::Application.routes.draw { mount ::DiscourseSms::Engine, at: "sms" }
