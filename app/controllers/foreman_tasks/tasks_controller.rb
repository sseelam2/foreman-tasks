module ForemanTasks
  class TasksController < ::ApplicationController
    include Foreman::Controller::AutoCompleteSearch
    include Foreman::Controller::CsvResponder

    before_action :restrict_dangerous_actions, :only => [:unlock, :force_unlock]

    def show
      @task = resource_base.find(params[:id])
      render :layout => !request.xhr?
    end

    def index
      params[:order] ||= 'started_at DESC'
      respond_with_tasks resource_base
    end

    def summary
      scope = resource_base.search_for(current_taxonomy_search).select(:id)
      render json: Task::Summarizer.new(Task.where(:id => scope), params[:recent_timeframe].to_i).summary
    end

    def sub_tasks
      # @task is used when rendering breadcrumbs
      @task = resource_base.find(params[:id])
      respond_with_tasks @task.sub_tasks
    end

    def cancel_step
      task = find_dynflow_task
      flash[:info] = _('Trying to cancel step %s') % params[:step_id]
      ForemanTasks.dynflow.world.event(task.external_id, params[:step_id].to_i, ::Dynflow::Action::Cancellable::Cancel).wait
      redirect_to foreman_tasks_task_path(task)
    end

    def cancel
      task = find_dynflow_task
      if task.cancel
        flash[:info] = _('Trying to cancel the task')
      else
        flash[:warning] = _('The task cannot be cancelled at the moment.')
      end
      redirect_back(:fallback_location => foreman_tasks_task_path(task))
    end

    def abort
      task = find_dynflow_task
      if task.abort
        flash[:info] = _('Trying to abort the task')
      else
        flash[:warning] = _('The task cannot be aborted at the moment.')
      end
      redirect_back(:fallback_location => foreman_tasks_task_path(task))
    end

    def resume
      task = find_dynflow_task
      if task.resumable?
        ForemanTasks.dynflow.world.execute(task.execution_plan.id)
        flash[:info] = _('The execution was resumed.')
      else
        flash[:warning] = _('The execution has to be resumable.')
      end
      redirect_back(:fallback_location => foreman_tasks_task_path(task))
    end

    def unlock
      task = find_dynflow_task
      if task.paused?
        task.state = :stopped
        task.save!
        flash[:info] = _('The task resources were unlocked.')
      else
        flash[:warning] = _('The execution has to be paused.')
      end
      redirect_back(:fallback_location => foreman_tasks_task_path(task))
    end

    def force_unlock
      task       = find_dynflow_task
      task.state = :stopped
      task.save!
      flash[:info] = _('The task resources were unlocked with force.')
      redirect_back(:fallback_location => foreman_tasks_task_path(task))
    end

    # we need do this to make the Foreman helpers working properly
    def controller_name
      'foreman_tasks_tasks'
    end

    def resource_class
      ForemanTasks::Task
    end

    private

    def respond_with_tasks(scope)
      respond_to do |format|
        format.html do
          @tasks = filter(scope)
          render :index, layout: !request.xhr?
        end
        format.csv do
          @tasks = filter(scope, paginate: false)
          csv_response(@tasks, [:id, :action, :state, :result, 'started_at.in_time_zone', 'ended_at.in_time_zone', :username], ['Id', 'Action', 'State', 'Result', 'Started At', 'Ended At', 'User'])
        end
      end
    end

    def restrict_dangerous_actions
      render_403 unless Setting['dynflow_allow_dangerous_actions']
    end

    def controller_permission
      'foreman_tasks'
    end

    def action_permission
      case params[:action]
      when 'sub_tasks', 'summary'
        :view
      when 'resume', 'unlock', 'force_unlock', 'cancel_step', 'cancel', 'abort'
        :edit
      else
        super
      end
    end

    def resource_scope(_options = {})
      @resource_scope ||= ForemanTasks::Task.authorized("#{action_permission}_foreman_tasks")
    end

    def find_dynflow_task
      resource_scope.where(:type => 'ForemanTasks::Task::DynflowTask').find(params[:id])
    end

    def filter(scope, paginate: true)
      search = current_taxonomy_search
      search = [search, params[:search]].select(&:present?).join(' AND ')
      scope = DashboardTableFilter.new(scope, params).scope
      scope = scope.search_for(search, :order => params[:order])
      scope = scope.paginate(:page => params[:page], :per_page => params[:per_page]) if paginate
      scope.distinct
    end

    def current_taxonomy_search
      conditions = []
      conditions << "organization_id = #{Organization.current.id}" if Organization.current
      conditions << "location_id = #{Location.current.id}" if Location.current
      conditions.empty? ? '' : "(#{conditions.join(' AND ')})"
    end
  end
end
