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

RSpec.describe Storages::ProjectStorages::CopyProjectFoldersService, :webmock do
  let(:storage) { create(:nextcloud_storage, :as_automatically_managed) }
  let(:target) { create(:project_storage, storage:) }
  let(:system_user) { create(:system) }

  subject(:service) { described_class }

  context "with automatically managed project folders" do
    let(:source) { create(:project_storage, :as_automatically_managed, storage:) }

    it 'if polling is required, returns a nil id and an url' do
      Storages::Peripherals::Registry
        .stub("#{source.storage.short_provider_type}.commands.copy_template_folder",
              ->(storage:, source_path:, destination_path:) do
                expect(storage).to eq(source.storage)
                expect(source_path).to eq(source.project_folder_location)
                expect(destination_path).to eq(target.managed_project_folder_path)

                # Return a success for the provider copy with no polling required
                ServiceResult.success(result: { id: nil, url: 'https://polling.url.de/cool/subresources' })
              end)

      result = service.call(source:, target:)

      expect(result).to be_success
      expect(result.result).to eq({ id: nil, url: 'https://polling.url.de/cool/subresources' })
    end
  end

  context "with manually managed project folders" do
    let(:source) { create(:project_storage, project_folder_id: 'this_is_a_unique_id', project_folder_mode: 'manual') }

    it "succeeds" do
      result = service.call(source:, target:)
      expect(result).to be_success
    end

    it 'returns the source folder id' do
      result = service.call(source:, target:)

      expect(result.result[:id]).to eq(source.project_folder_id)
    end
  end

  context "with non-managed project folders" do
    let(:source) { create(:project_storage, project_folder_id: nil, project_folder_mode: 'inactive') }

    it "succeeds" do
      expect(service.call(source:, target:)).to be_success
    end

    it 'returns the origin folder id (nil)' do
      result = service.call(source:, target:)

      expect(result.result[:id]).to eq(source.project_folder_id)
    end
  end
end
