require_dependency 'issue'

module Backlogs
  module IssuePatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do
        unloadable

        alias_method_chain :move_to_project_without_transaction, :autolink
        alias_method_chain :recalculate_attributes_for, :remaining_hours
        before_validation :backlogs_before_validation, :if => lambda {|i| i.project && i.project.module_enabled?("backlogs")}

        after_save  :touch_sprint_burndowns
        before_save :inherit_version_from_parent, :if => lambda {|i| i.is_task? and i.fixed_version_id.blank? }
        after_save  :inherit_version_of_story, :if => lambda {|i| i.is_story? and i.changed? }

        validates_numericality_of :story_points, :only_integer             => true,
                                                 :allow_nil                => true,
                                                 :greater_than_or_equal_to => 0,
                                                 :less_than                => 10_000,
                                                 :if => lambda { |i| i.project && i.project.module_enabled?('backlogs') }

        validates_each :fixed_version_id do |record, field, value|
          if record.is_task? and record.fixed_version_id_changed? and record.fixed_version_id != record.story.fixed_version_id
            record.errors.add :fixed_version_id, :task_version_must_be_the_same_as_story_version
          end
        end       

      end
    end

    module ClassMethods
    end

    module InstanceMethods
      def move_to_project_without_transaction_with_autolink(new_project, new_tracker = nil, options = {})
        newissue = move_to_project_without_transaction_without_autolink(new_project, new_tracker, options)

        if !!newissue and self.project_id == newissue.project_id and self.is_story? and newissue.is_story? and self.id != newissue.id
          relation = IssueRelation.new :relation_type => IssueRelation::TYPE_DUPLICATES
          relation.issue_from = self
          relation.issue_to = newissue
          relation.save
        end

        return newissue
      end

      def journalized_update_attributes!(attribs)
        init_journal(User.current)
        update_attributes!(attribs)
      end

      def journalized_update_attributes(attribs)
        init_journal(User.current)
        update_attributes(attribs)
      end

      def journalized_update_attribute(attrib, v)
        init_journal(User.current)
        update_attribute(attrib, v)
      end

      def is_story?
        backlogs_enabled? and Story.trackers.include?(self.tracker_id)
      end

      def is_task?
        backlogs_enabled? and (self.parent_id && self.tracker_id == Task.tracker && Task.tracker.present?)
      end

      def story
        if self.is_story?
          return Story.find(self.id)
        elsif self.is_task?
          # Make sure to get the closest ancestor that is a Story, i.e. the one with the highest lft
          # otherwise, the highest parent that is a Story is returned
          story_issue = self.ancestors.find_by_tracker_id(Story.trackers, :order => 'lft DESC')
          return Story.find(story_issue.id) if story_issue
        end
        nil
      end

      def blocks
        # return issues that I block that aren't closed
        return [] if closed?
        relations_from.collect {|ir| ir.relation_type == 'blocks' && !ir.issue_to.closed? ? ir.issue_to : nil}.compact
      end

      def blockers
        # return issues that block me
        return [] if closed?
        relations_to.collect {|ir| ir.relation_type == 'blocks' && !ir.issue_from.closed? ? ir.issue_from : nil}.compact
      end

      def velocity_based_estimate
        return nil if !self.is_story? || !self.story_points || self.story_points <= 0

        dpp = self.project.scrum_statistics.info[:average_days_per_point]
        return nil if !dpp

        return Integer(self.story_points * dpp)
      end

      def recalculate_attributes_for_with_remaining_hours(issue_id)
        recalculate_attributes_for_without_remaining_hours(issue_id)

        if issue_id && p = Issue.find_by_id(issue_id)
          if p.left != (p.right + 1) # this node has children
            p.update_attribute(:remaining_hours, p.leaves.sum(:remaining_hours).to_f)
          end
        end
      end
      
      def inherit_version_from(parent)
        if parent
          self.fixed_version_id = parent.fixed_version_id
        end
      end

      private
      def backlogs_before_validation
        if self.tracker_id == Task.tracker
          self.estimated_hours = self.remaining_hours if self.estimated_hours.blank? && ! self.remaining_hours.blank?
          self.remaining_hours = self.estimated_hours if self.remaining_hours.blank? && ! self.estimated_hours.blank?
        end
      end
      
      def inherit_version_from_parent
        inherit_version_from(self.story)
        true
      end
      
      def inherit_version_of_story
        story = self.story or return true
        story.inherit_version_to_subtasks
      end

      def touch_sprint_burndowns
        ## Normally one of the _before_save hooks ought to take
        ## care of this, but appearantly neither root_id nor
        ## parent_id are set at that point

        touched_sprints = []
        story = self.story

        if self.is_story?
          touched_sprints = Sprint.find_all_by_id(
            [self.fixed_version_id, self.fixed_version_id_was].compact)
        elsif self.is_task?
          # for tasks we touch the sprints of the current and former stories
          story_was = nil
          story_was = Issue.find(self.parent_id_was).story if self.parent_id_was
          touched_sprints = [story, story_was].compact.collect{ |s| s.fixed_version }
        end

        touched_sprints.compact.uniq.each {|sprint|
          sprint.touch_burndown
        }
      end

      def backlogs_enabled?
        self.project.module_enabled?("backlogs")
      end

    end
  end
end

Issue.send(:include, Backlogs::IssuePatch) unless Issue.included_modules.include? Backlogs::IssuePatch
