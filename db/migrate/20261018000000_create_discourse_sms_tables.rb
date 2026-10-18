# frozen_string_literal: true

class CreateDiscourseSmsTables < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_sms_phone_bindings do |t|
      t.integer :user_id, null: false
      t.string :phone_number, null: false, limit: 20
      t.datetime :verified_at, null: false
      t.timestamps
    end

    add_index :discourse_sms_phone_bindings, :user_id, unique: true
    add_index :discourse_sms_phone_bindings, :phone_number, unique: true

    create_table :discourse_sms_verification_challenges do |t|
      t.integer :user_id, null: false
      t.string :phone_number, null: false, limit: 20
      t.datetime :sent_at, null: false
      t.datetime :expires_at, null: false
      t.integer :attempts, null: false, default: 0
      t.timestamps
    end

    add_index :discourse_sms_verification_challenges, :user_id, unique: true
    add_index :discourse_sms_verification_challenges, :expires_at
  end
end
