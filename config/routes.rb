# frozen_string_literal: true

DiscourseSms::Engine.routes.draw do
  get "/status" => "sms#status"
  post "/send_code" => "sms#send_code"
  post "/verify_code" => "sms#verify_code"
end

Discourse::Application.routes.draw { mount ::DiscourseSms::Engine, at: "sms" }
