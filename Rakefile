# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |t|
  t.libs << "test"
  t.libs << "lib"
  t.warning = false
end

task default: :test
