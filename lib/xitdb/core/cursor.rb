# frozen_string_literal: true

module XitDB
  module Core
    class Cursor
      attr_reader :database, :transaction

      def initialize(database:, slot:, bound:, transaction: nil)
        @database = database
        @slot = slot
        @bound = bound
        @transaction = transaction
      end

      def slot
        database.check_open!
        transaction&.check_cursor!(self)
        @slot
      end

      def bound
        slot
        transaction ? transaction.length : @bound
      end

      def replace(slot)
        database.check_open!
        raise ReadOnlyError, "cursor is read-only" unless transaction

        transaction.check_replacement!(self, slot)
        @slot = slot
        self
      end

      def read_bytes
        database.read_bytes(slot, bound: bound)
      end
    end
  end
end
