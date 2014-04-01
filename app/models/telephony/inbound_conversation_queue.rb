require 'redis-objects'

module Telephony
  class InboundConversationQueue
    def self.play_message(args)
      Conversation.transaction do
        conversation = Conversation.create_inbound! number: args[:To], caller_id: args[:To]
        conversation.play_message!
        customer_leg = conversation.calls.create! number: args[:From], sid: args[:CallSid]
        customer_leg.connect!
        customer_leg.answer!
        conversation
      end
    end

    def self.play_closed_greeting(args)
      Conversation.transaction do
        conversation = Conversation.create_inbound! number: args[:To], caller_id: args[:To]
        conversation.play_closed_greeting!
        customer_leg = conversation.calls.create! number: args[:From], sid: args[:CallSid]
        customer_leg.terminate!
        conversation
      end
    end

    def self.reject(args)
      Conversation.transaction do
        conversation = Conversation.create_inbound! number: args[:To], caller_id: args[:To]
        customer_leg = conversation.calls.create! number: args[:From], sid: args[:CallSid]
        customer_leg.reject!
        conversation
      end
    end

    def self.dequeue(csr_id)
      with_agent_on_a_call(csr_id) do |agent|
        begin
          conversation = oldest_queued_conversation

          if conversation
            agent_call = conversation.calls.create! number: agent.phone_number, agent: agent
            agent_call.connect!

            conversation.customer.redirect_to_inbound_connect csr_id

            pop_url = Telephony.pop_url_finder &&
                      Telephony.pop_url_finder.find(conversation.customer.sanitized_number)

            {
              id: conversation.id,
              customer_number: conversation.customer.number,
              pop_url: pop_url
            }
          else
            raise Telephony::Error::QueueEmpty.new
          end
        rescue Telephony::Error::NotInProgress => e
          agent_call.destroy
          conversation.customer.terminate!
          Rails.logger.info("InboundConversationQueue.dequeue: Can't redirect call, retrying: Conversation #{conversation.id}: #{e.inspect}")
          retry
        end
      end
    end

    def self.oldest_queued_conversation
      # Pop redis queue and use the id to find and return the associated conversation.
      conversation = nil
      while conversation.nil? && queue.count > 0
        conversation = Conversation.where(id: pop, state: 'enqueued').first
      end

      Conversation.transaction do
        conversation.connect! if conversation
        conversation
      end
    end

    def self.push(conversation_id)
      queue.push(conversation_id)
    end

    def self.pop
      queue.shift
    end

    def self.queue
      @@queue ||= Redis::List.new("conversation_queue")
    end

    private

    def self.with_agent_on_a_call csr_id
      old_status = ''
      agent = nil

      Agent.transaction do
        agent = Agent.find_by_csr_id(csr_id, lock: true)

        if agent.on_a_call?
          raise Telephony::Error::AgentOnACall.new
        else
          old_status = agent.status
          agent.on_a_call
        end

        begin
          yield agent
        rescue => error
          agent.fire_events old_status
          raise error
        end
      end
    end
  end
end
