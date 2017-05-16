require 'spec_helper'
require 'timecop'

module Bosh::Director
  describe AgentBroadcaster do
    let(:ip_addresses) { ['10.0.0.1'] }
    let(:instance1) do
      instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 1, job: 'fake-job-1')
      Bosh::Director::Models::Vm.make(id: 1, agent_id: 'agent-1', cid: 'id-1', instance_id: instance.id, active: true)
      instance
    end
    let(:instance2) do
      instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 2, job: 'fake-job-1')
      Bosh::Director::Models::Vm.make(id: 2, agent_id: 'agent-2', cid: 'id-2', instance_id: instance.id, active: true)
      instance
    end
    let(:agent) { instance_double(AgentClient, wait_until_ready: nil, delete_arp_entries: nil) }
    let(:agent_broadcast) { AgentBroadcaster.new(0.1) }

    describe '#filter_instances' do
      it 'excludes the VM being created' do
        3.times do |i|
          Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: i, job: "fake-job-#{i}")
        end

        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0')
        vm_being_created = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance_id: instance.id, active: true)

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created.cid)

        expect(instances.count).to eq 0
      end

      it 'excludes instances where the vm is nil' do
        3.times do |i|
          Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: i, job: "fake-job-#{i}")
        end
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances.count).to eq 0
      end

      it 'excludes compilation VMs' do
        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0', compilation: true)
        active_vm = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance: instance, active: true)
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances.count).to eq 0
      end

      it 'includes VMs that need flushing' do
        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0')
        active_vm = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance: instance, active: true)
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances).to eq [instance]
      end
    end

    describe '#delete_arp_entries' do
      it 'successfully broadcast :delete_arp_entries call' do
        expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
            with(instance1.credentials, instance1.agent_id).and_return(agent)
        expect(agent).to receive(:send).with(:delete_arp_entries, ips: ip_addresses)

        agent_broadcast.delete_arp_entries('fake-vm-cid-to-exclude', ip_addresses)
      end

      it 'successfully filers out id-1 and broadcast :delete_arp_entries call' do
        expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
            with(instance1.credentials, instance1.agent_id).and_return(agent)
        expect(AgentClient).to_not receive(:with_vm_credentials_and_agent_id).
            with(instance2.credentials, instance2.agent_id)
        expect(agent).to receive(:delete_arp_entries).with(ips: ip_addresses)

        agent_broadcast.delete_arp_entries('id-2', ip_addresses)
      end
    end

    describe '#sync_dns' do
      let(:start_time) { Time.now }
      let(:end_time) { start_time + 0.01 }

      before do
        Timecop.freeze(start_time)
      end

      context 'when all agents are responsive' do
        it 'successfully broadcast :sync_dns call' do
          expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 1 agents ["agent-1"]')
          expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: attempted 1 agents in 10ms (1 successful, 0 failed, 0 unresponsive)')

          expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
              with(instance1.credentials, instance1.agent_id).and_return(agent)
          expect(agent).to receive(:send).with(:sync_dns, 'fake-blob-id', 'fake-sha1', 1) do |&blk|
            blk.call({'value' => 'synced'})
            Timecop.freeze(end_time)
          end

          agent_broadcast.sync_dns([instance1], 'fake-blob-id', 'fake-sha1', 1)

          expect(Models::AgentDnsVersion.all.length).to eq(1)
        end
      end

      context 'when some agents fail' do
        let!(:instances) { [instance1, instance2]}

        context 'and agent succeeds within retry count' do
          it 'retries broadcasting to failed agents' do
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 2 agents ["agent-1", "agent-2"]')
            expect(logger).to receive(:error).with('agent_broadcaster: sync_dns[agent-2]: received unexpected response {"value"=>"unsynced"}')
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: attempted 2 agents in 10ms (1 successful, 1 failed, 0 unresponsive)')

            expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
              with(instance1.credentials, instance1.agent_id) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'synced'})
                Timecop.freeze(end_time)
              end
              agent
            end

            expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
              with(instance2.credentials, instance2.agent_id) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'unsynced'})
              end
              agent
            end

            agent_broadcast.sync_dns(instances, 'fake-blob-id', 'fake-sha1', 1)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
          end
        end
      end


      context 'when some agents are unresponsive' do
        let!(:instances) { [instance1, instance2]}

        context 'and agent succeeds within retry count' do
          it 'retries broadcasting to failed agents' do
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 2 agents ["agent-1", "agent-2"]')
            expect(logger).to receive(:warn).with('agent_broadcaster: sync_dns[agent-2]: no response received')
            expect(logger).to receive(:info).with(/agent_broadcaster: sync_dns: attempted 2 agents in \d+ms \(1 successful, 0 failed, 1 unresponsive\)/)

            expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
              with(instance1.credentials, instance1.agent_id) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'synced'})
                Timecop.travel(end_time)
              end
              agent
            end

            expect(AgentClient).to receive(:with_vm_credentials_and_agent_id).
              with(instance2.credentials, instance2.agent_id) do
              expect(agent).to receive(:sync_dns)
              agent
            end.twice

            agent_broadcast.sync_dns(instances, 'fake-blob-id', 'fake-sha1', 1)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
          end
        end
      end
    end
  end
end
