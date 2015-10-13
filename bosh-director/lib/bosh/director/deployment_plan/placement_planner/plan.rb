module Bosh
  module Director
    module DeploymentPlan
      module PlacementPlanner
        class Plan
          def initialize(desired, existing, networks, availability_zones, job_name)
            @networks = networks
            @desired = desired
            @existing = existing
            @availability_zones = availability_zones
            @job_name = job_name
          end

          def needed
            results[:desired_new]
          end

          def existing
            results[:desired_existing]
          end

          def obsolete
            results[:obsolete]
          end

          private

          def results
            @results ||= begin
              results = assign_zones
              IndexAssigner.new.assign_indexes(results)
              results
            end
          end

          def assign_zones
            if has_static_ips?
              StaticIpsAvailabilityZonePicker.new.place_and_match_in(@availability_zones, @networks, @desired, @existing, @job_name)
            else
              AvailabilityZonePicker.new.place_and_match_in(@availability_zones, @desired, @existing)
            end
          end

          def has_static_ips?
            !@networks.nil? && @networks.any? { |network| !! network.static_ips }
          end
        end
      end
    end
  end
end