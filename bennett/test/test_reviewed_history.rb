# frozen_string_literal: true

require 'open3'
require_relative 'helper'

class ReviewedHistoryTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('bennett-reviewed-history-')
    @repo = File.join(@root, 'repo')
    @origin = File.join(@root, 'origin.git')
    FileUtils.mkdir_p(@repo)
    git('init', '--quiet', '-b', 'main')
    git('config', 'user.name', 'Synthetic reviewer')
    git('config', 'user.email', 'reviewer@example.invalid')
    write('app.txt', "original\n")
    commit('base')
    base = git('rev-parse', 'HEAD')
    write('bennett.txt', "firm changes\n")
    commit('fork')
    fork = git('rev-parse', 'HEAD')
    git('checkout', '--quiet', '-b', 'upstream', base)
    write('app.txt', "upstream version\n")
    commit('upstream')
    @upstream = git('rev-parse', 'HEAD')
    git('checkout', '--quiet', '-b', 'reviewed', fork)
    git('merge', '--quiet', '--no-ff', '-m', 'Reviewed upstream integration', @upstream)
    @anchor = git('rev-parse', 'HEAD')
    git('init', '--quiet', '--bare', @origin)
    git('remote', 'add', 'origin', @origin)
    git('push', '--quiet', 'origin', "#{@anchor}:refs/pull/25/head")
    git('checkout', '--quiet', '-b', 'squashed', fork)
    git('cherry-pick', '--quiet', '-m', '1', @anchor)
    write('later-fix.txt', "later reviewed fix\n")
    commit('subsequent fix')
    @before = git('rev-parse', 'HEAD')
    @tree = git('rev-parse', 'HEAD^{tree}')
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_restores_parents_without_changing_source_or_later_fixes
    refute ancestor?(@upstream)
    assert restore[2].success?
    assert ancestor?(@upstream)
    assert ancestor?(@before)
    assert_equal @tree, git('rev-parse', 'HEAD^{tree}')
    assert_equal [@before, @anchor], git('show', '-s', '--format=%P', 'HEAD').split
    assert_equal "later reviewed fix\n", File.read(File.join(@repo, 'later-fix.txt'))
  end

  def test_an_existing_restoration_is_a_no_op
    assert restore[2].success?
    head = git('rev-parse', 'HEAD')
    assert restore[2].success?
    assert_equal head, git('rev-parse', 'HEAD')
  end

  def test_rejects_a_changed_reference_without_touching_the_checkout
    refute restore(@upstream)[2].success?
    assert_unchanged
  end

  def test_rejects_source_changes_and_aborts_the_merge
    git('checkout', '--quiet', 'reviewed')
    write('unreviewed.txt', "must not enter release\n")
    commit('unexpected source')
    altered = git('rev-parse', 'HEAD')
    git('push', '--quiet', 'origin', "#{altered}:refs/pull/25/head")
    git('checkout', '--quiet', 'squashed')
    refute restore(altered)[2].success?
    assert_unchanged
    refute File.exist?(File.join(@repo, 'unreviewed.txt'))
    refute File.exist?(File.join(@repo, '.git', 'MERGE_HEAD'))
  end

  def test_dirty_work_is_preserved_and_refused
    write('app.txt', "unsaved operator work\n")
    refute restore[2].success?
    assert_equal @before, git('rev-parse', 'HEAD')
    assert_equal "unsaved operator work\n", File.read(File.join(@repo, 'app.txt'))
  end

  private

  def restore(expected = @anchor)
    Open3.capture3('bash', '-c', 'source "$1"; restore_reviewed_history refs/pull/25/head "$2"',
                   'test', BennettTest.path('bennett/ci/restore-reviewed-history.sh'), expected, chdir: @repo)
  end

  def assert_unchanged
    assert_equal @before, git('rev-parse', 'HEAD')
    assert_equal @tree, git('write-tree')
    assert_empty git('status', '--porcelain')
  end

  def ancestor?(commit)
    Open3.capture3('git', 'merge-base', '--is-ancestor', commit, 'HEAD', chdir: @repo)[2].success?
  end

  def write(path, contents)
    File.write(File.join(@repo, path), contents)
  end

  def commit(message)
    git('add', '.')
    git('commit', '--quiet', '-m', message)
  end

  def git(*)
    out, err, status = Open3.capture3('git', *, chdir: @repo)
    raise "Fixture git failed: #{err}" unless status.success?

    out.strip
  end
end
