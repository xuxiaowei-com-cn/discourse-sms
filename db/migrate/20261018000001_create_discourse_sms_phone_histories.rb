# frozen_string_literal: true

class CreateDiscourseSmsPhoneHistories < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_sms_phone_histories do |t|
      t.integer :user_id, null: false
      t.string :phone_number, null: false, limit: 20
      t.string :event_type, null: false, limit: 20
      t.timestamps
    end

    add_index :discourse_sms_phone_histories, :user_id
    add_index :discourse_sms_phone_histories, :phone_number
    add_index :discourse_sms_phone_histories, %i[user_id created_at]
  end
end
