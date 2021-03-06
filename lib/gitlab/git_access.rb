module Gitlab
  class GitAccess
    DOWNLOAD_COMMANDS = %w{ git-upload-pack git-upload-archive }
    PUSH_COMMANDS = %w{ git-receive-pack }

    attr_reader :params, :project, :git_cmd, :user

    def check(actor, cmd, project, changes = nil)
      case cmd
      when *DOWNLOAD_COMMANDS
        if actor.is_a? User
          download_access_check(actor, project)
        elsif actor.is_a? DeployKey
          actor.projects.include?(project)
        elsif actor.is_a? Key
          download_access_check(actor.user, project)
        else
          raise 'Wrong actor'
        end
      when *PUSH_COMMANDS
        if actor.is_a? User
          push_access_check(actor, project, changes)
        elsif actor.is_a? DeployKey
          return build_status_object(false, "Deploy key not allowed to push")
        elsif actor.is_a? Key
          push_access_check(actor.user, project, changes)
        else
          raise 'Wrong actor'
        end
      else
        return build_status_object(false, "Wrong command")
      end
    end

    def download_access_check(user, project)
      if user && user_allowed?(user) && user.can?(:download_code, project)
        build_status_object(true)
      else
        build_status_object(false, "You don't have access")
      end
    end

    def push_access_check(user, project, changes)
      return build_status_object(false, "You don't have access") unless user && user_allowed?(user)
      return build_status_object(true) if changes.blank?

      changes = changes.lines if changes.kind_of?(String)

      # Iterate over all changes to find if user allowed all of them to be applied
      changes.each do |change|
        status = change_access_check(user, project, change)
        unless status.allowed?
          # If user does not have access to make at least one change - cancel all push
          return status
        end
      end

      return build_status_object(true)
    end

    def change_access_check(user, project, change)
      oldrev, newrev, ref = change.split(' ')

      action = if project.protected_branch?(branch_name(ref))
                 # we dont allow force push to protected branch
                 if forced_push?(project, oldrev, newrev)
                   :force_push_code_to_protected_branches
                   # and we dont allow remove of protected branch
                 elsif newrev == Gitlab::Git::BLANK_SHA
                   :remove_protected_branches
                 else
                   :push_code_to_protected_branches
                 end
               elsif project.repository && project.repository.tag_names.include?(tag_name(ref))
                 # Prevent any changes to existing git tag unless user has permissions
                 :admin_project
               else
                 :push_code
               end

      if user.can?(action, project)
        build_status_object(true)
      else
        build_status_object(false, "You don't have permission")
      end
    end

    def forced_push?(project, oldrev, newrev)
      return false if project.empty_repo?

      if oldrev != Gitlab::Git::BLANK_SHA && newrev != Gitlab::Git::BLANK_SHA
        missed_refs = IO.popen(%W(git --git-dir=#{project.repository.path_to_repo} rev-list #{oldrev} ^#{newrev})).read
        missed_refs.split("\n").size > 0
      else
        false
      end
    end

    private

    def user_allowed?(user)
      Gitlab::UserAccess.allowed?(user)
    end

    def branch_name(ref)
      ref = ref.to_s
      if ref.start_with?('refs/heads')
        ref.sub(%r{\Arefs/heads/}, '')
      else
        nil
      end
    end

    def tag_name(ref)
      ref = ref.to_s
      if ref.start_with?('refs/tags')
        ref.sub(%r{\Arefs/tags/}, '')
      else
        nil
      end
    end

    protected

    def build_status_object(status, message = '')
      GitAccessStatus.new(status, message)
    end
  end
end
