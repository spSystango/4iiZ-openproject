# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2024 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require 'spec_helper'
require_module_spec_helper

RSpec.describe Storages::CopyProjectFoldersJob, :job, :webmock do
  include ActiveJob::TestHelper

  let(:storage) { create(:nextcloud_storage, :as_automatically_managed) }
  let(:source) { create(:project_storage, :as_automatically_managed, storage:) }
  let(:user) { create(:admin) }

  let(:source_work_packages) { create_list(:work_package, 4, project: source.project) }

  let(:target) { create(:project_storage, storage: source.storage) }
  let(:target_work_packages) { create_list(:work_package, 4, project: target.project) }

  let(:work_package_map) do
    source_work_packages
      .pluck(:id)
      .map(&:to_s)
      .zip(target_work_packages.pluck(:id))
      .to_h
  end

  let(:polling_url) { 'https://polling.url.de/cool/subresources' }

  let(:target_deep_file_ids) do
    source_file_links.each_with_object({}) do |fl, hash|
      hash["#{target.managed_project_folder_path}#{fl.name}"] = "RANDOM_ID_#{fl.hash}"
    end
  end

  let(:source_file_links) { source_work_packages.map { |wp| create(:file_link, container: wp, storage:) } }
  let(:source_file_infos) do
    source_file_links.map do |fl|
      Storages::StorageFileInfo.new(
        status: 'ok',
        status_code: 200,
        id: fl.origin_id,
        name: fl.name,
        location: "#{source.managed_project_folder_path}#{fl.name}"
      )
    end
  end

  before do
    # Limit the number of retries on tests
    described_class.retry_on Storages::Errors::PollingRequired, wait: 1, attempts: 3
    source_file_links
  end

  describe "non-automatic managed folders" do
    let(:inverted_wp_map) { work_package_map.invert }

    before do
      source.update(project_folder_mode: 'manual', project_folder_id: 'awesome-folder')
      source.reload
    end

    it 'updates the target project storage project_folder_id to match the source' do
      perform_enqueued_jobs(only: described_class) do
        described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
      end

      target.reload
      expect(target.project_folder_id).to eq(source.project_folder_id)
    end

    it 'copies all the file link info on the corresponding work_package' do
      perform_enqueued_jobs(only: described_class) do
        described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
      end

      WorkPackage.includes(:file_links).where(id: work_package_map.values).find_each do |target_wp|
        expect(target_wp.file_links.count).to eq(1)

        file_link = target_wp.file_links.first
        source_file_link = source_file_links.find do |fl|
          fl.container_id == inverted_wp_map[target_wp.id].to_i
        end

        expect(file_link.origin_name).to eq(source_file_link.origin_name)
        expect(file_link.origin_id).to eq(source_file_link.origin_id)
      end
    end
  end

  # rubocop:disable Lint/UnusedBlockArgument
  describe "managed project folders" do
    before do
      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.queries.folder_files_file_ids_deep_query", ->(storage:, folder:) {
          ServiceResult.success(result: target_deep_file_ids)
        })

      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.queries.files_info", ->(storage:, user:, file_ids:) {
          ServiceResult.success(result: source_file_infos)
        })

      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.commands.copy_template_folder", ->(storage:, source_path:, destination_path:) {
          ServiceResult.success(result: { id: 'copied-folder', url: 'resource-url' })
        })
    end

    it 'copies the folders from source to target' do
      perform_enqueued_jobs(only: described_class) do
        described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
      end

      target.reload
      expect(target.project_folder_mode).to eq(source.project_folder_mode)
      expect(target.project_folder_id).to eq('copied-folder')
    end

    it 'creates the file links pointing to the newly copied files' do
      perform_enqueued_jobs(only: described_class) do
        described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
      end

      Storages::FileLink.where(container: target_work_packages).find_each do |file_link|
        expect(file_link.origin_id).to eq(target_deep_file_ids["#{target.managed_project_folder_path}#{file_link.name}"])
      end
    end
  end

  context "when the storage requires polling" do
    before do
      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.commands.copy_template_folder", ->(storage:, source_path:, destination_path:) {
          ServiceResult.success(result: { id: nil, url: polling_url })
        })

      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.queries.folder_files_file_ids_deep_query", ->(storage:, folder:) {
          ServiceResult.success(result: target_deep_file_ids)
        })

      Storages::Peripherals::Registry
        .stub("#{storage.short_provider_type}.queries.files_info", ->(storage:, user:, file_ids:) {
          ServiceResult.success(result: source_file_infos)
        })
    end

    it 'raises a Storages::Errors::PollingRequired' do
      perform_enqueued_jobs(only: described_class) do
        expect do
          described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
        end.to raise_error Storages::Errors::PollingRequired
      end
    end

    it 'stores the polling url on the current thread' do
      job = described_class.new

      perform_enqueued_jobs(only: described_class) do
        expect do
          job.perform(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
        end.to raise_error Storages::Errors::PollingRequired
      end

      expect(Thread.current[job.job_id]).to eq(polling_url)
    end

    context 'when the polling completes' do
      let(:copy_incomplete_response) do
        { operation: "ItemCopy", percentageComplete: 27.8, status: "inProgress" }.to_json
      end

      let(:copy_complete_response) do
        { percentageComplete: 100.0, resourceId: "01MOWKYVJML57KN2ANMBA3JZJS2MBGC7KM", status: "completed" }.to_json
      end

      before do
        stub_request(:get, polling_url)
          .and_return(
            { status: 202, body: copy_incomplete_response, headers: { 'Content-Type' => 'application/json' } },
            { status: 202, body: copy_complete_response, headers: { 'Content-Type' => 'application/json' } }
          )
      end

      it 'updates the storages' do
        perform_enqueued_jobs(only: described_class) do
          described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
        end

        target.reload
        expect(target.project_folder_mode).to eq(source.project_folder_mode)
        expect(target.project_folder_id).to eq('01MOWKYVJML57KN2ANMBA3JZJS2MBGC7KM')
      end

      it 'handles re-enqueues and polling' do
        perform_enqueued_jobs(only: described_class) do
          described_class.perform_now(source_id: source.id, target_id: target.id, work_package_map:, user_id: user.id)
        end

        performed_job = ActiveJob::Base.queue_adapter.performed_jobs.find { |jobs| jobs['job_class'] == described_class.to_s }
        expect(performed_job['exception_executions']['[Storages::Errors::PollingRequired]']).to eq(2)
        expect(performed_job['executions']).to eq(1)
      end
    end
  end
  # rubocop:enable Lint/UnusedBlockArgument
end
