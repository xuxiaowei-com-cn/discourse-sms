# frozen_string_literal: true

class CreateDiscourseSmsRegistrationChallenges < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_sms_registration_challenges do |t|
      t.string :phone_number, null: false, limit: 20
      t.datetime :sent_at, null: false
      t.datetime :expires_at, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :verified_at
      t.string :token_digest, limit: 64
      t.datetime :token_expires_at
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :discourse_sms_registration_challenges, :phone_number, unique: true
    add_index :discourse_sms_registration_challenges, :token_digest, unique: true
    add_index :discourse_sms_registration_challenges, :expires_at
  end
end
