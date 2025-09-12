def git_commit_grayscale(contribution_count, opts = {})
  if opts[:framework_v2] == false # @lucian opt-in to v1 colors
    case contribution_count
    when 1..3
      'bg--gray-5'
    when 4..7
      'bg--gray-4'
    when 8..10
      'bg--gray-3'
    when 11..20
      'bg--gray-2'
    when 20..1000
      'bg-black'
    end
  else
    case contribution_count
    when 1
      'bg--gray-60'
    when 2
      'bg--gray-55'
    when 3
      'bg--gray-50'
    when 4
      'bg--gray-45'
    when 5
      'bg--gray-40'
    when 6
      'bg--gray-35'
    when 7..8
      'bg--gray-30'
    when 9..10
      'bg--gray-25'
    when 11..12
      'bg--gray-20'
    when 13..15
      'bg--gray-15'
    when 16..20
      'bg--gray-10'
    when 21..1000
      'bg-black'
    end
  end
end
