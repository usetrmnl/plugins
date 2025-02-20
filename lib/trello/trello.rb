module Plugins
  class ProjectBoard < Base
    TASK_DATA = JSON.parse(File.read("db/data/tasks.json"))

    def locals
      { 
        pending_tasks: TASK_DATA['pendingTasks'],
        in_progress_tasks: TASK_DATA['inProgressTasks'], 
        completed_tasks: TASK_DATA['completedTasks'],
        hide_description: settings['hide_description'] == 'yes',
        hide_owner: settings['hide_owner'] == 'yes'
      }
    end

    private

    def tag_colors
      {
        'Backend' => '#3b82f6',
        'Documentation' => '#22c55e', 
        'UI/UX' => '#8b5cf6',
        'DevOps' => '#0d9488',
        'Infrastructure' => '#4c1d95',
        'Security' => '#f59e0b',
        'Fixed' => '#059669',
        'High Priority' => '#ef4444'
      }
    end
  end
end