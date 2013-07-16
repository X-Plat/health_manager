module HealthManager
  class ActualState
    include HealthManager::Common
    attr_reader :varz
    attr_accessor :harmonizer

    def initialize(varz, droplet_registry)
      @droplet_registry = droplet_registry
      @varz = varz
    end

    def cc_partition_match?(message)
      cc_partition == message['cc_partition']
    end

    def check_availability
      was_available = @available
      @available = available?

      if @available && !was_available
        initialize_subscriptions
      end

      if was_available && !@available
        logger.warn "hm.actual-state.nats-connection-lost"
      end
    end

    def initialize_subscriptions
      logger.info "hm.actual-state.subscribing"

      NATS.subscribe('dea.heartbeat') do |message|
        process_heartbeat(message)
      end

      NATS.subscribe('droplet.exited') do |message|
        process_droplet_exited(message)
      end

      NATS.subscribe('droplet.updated') do |message|
        process_droplet_updated(message)
      end
    end

    def start
      check_availability
    end

    def available?
      NATS.connected?
    end

    private

    def process_droplet_exited(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug "hm.actual-state.process-droplet-exited",
                   :message => message

      varz[:droplet_exited_msgs_received] += 1

      droplet = get_droplet(message)

      droplet.mark_instance_as_down(message['version'],
                                    message['index'],
                                    message['instance'])

      case message['reason']
      when CRASHED
        varz[:crashed_instances] += 1
        droplet.process_exit_crash(message)
        harmonizer.on_exit_crashed(droplet, message)
      when DEA_SHUTDOWN, DEA_EVACUATION
        droplet.reset_missing_indices
        harmonizer.on_exit_dea(droplet, message)
      when STOPPED
        droplet.reset_missing_indices
        harmonizer.on_exit_stopped(message)
      end
    end

    def process_heartbeat(message_str)
      message = parse_json(message_str)

      logger.debug "hm.actual-state.process-heartbeat",
                   :dea => message["dea"]

      varz[:heartbeat_msgs_received] += 1

      message['droplets'].each do |beat|
        next unless cc_partition_match?(beat)
        droplet = get_droplet(beat)
        droplet.process_heartbeat(Heartbeat.new(beat))
        harmonizer.on_extra_instances(droplet, droplet.extra_instances)
      end
    end

    def process_droplet_updated(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug "hm.actual-state.process-droplet-updated",
                   :droplet => message["droplet"]

      varz[:droplet_updated_msgs_received] += 1
      droplet = get_droplet(message)
      droplet.reset_missing_indices
      harmonizer.on_droplet_updated(droplet, message)
    end

    def get_droplet(message)
      @droplet_registry.get(message['droplet'].to_s)
    end
  end
end
