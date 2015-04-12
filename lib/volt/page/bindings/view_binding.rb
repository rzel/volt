require 'volt/page/bindings/base_binding'
require 'volt/page/template_renderer'
require 'volt/page/bindings/view_binding/grouped_controllers'
require 'volt/page/bindings/view_binding/view_lookup_for_path'
require 'volt/page/bindings/view_binding/controller_lifecycle'


module Volt
  class ViewBinding < BaseBinding

    # @param [String]     binding_in_path is the path this binding was rendered from.  Used to
    #                     lookup paths in ViewLookupForPath
    # @param [String|nil] content_template_path is the path to the template for the content
    #                     provided in the tag.
    def initialize(page, target, context, binding_name, binding_in_path, getter, content_template_path=nil)
      super(page, target, context, binding_name)

      @content_template_path = content_template_path

      # Setup the view lookup helper
      @view_lookup = Volt::ViewLookupForPath.new(page, binding_in_path)

      @current_template = nil

      # Run the initial render
      @computation      = -> do
        # Don't try to render if this has been removed
        if @context
          # Render
          update(*@context.instance_eval(&getter))
        end
      end.watch!
    end

    def update(path, section_or_arguments = nil, options = {})
      Computation.run_without_tracking do
        @options = options

        # A blank path needs to load a missing template, otherwise it tries to load
        # the same template.
        path     = path.blank? ? '---missing---' : path

        section    = nil
        @arguments = nil

        if section_or_arguments.is_a?(String)
          # Render this as a section
          section = section_or_arguments
        else
          # Use the value passed in as the default arguments
          @arguments = section_or_arguments

          # Include content_template_path in attrs
          if @content_template_path
            @arguments ||= {}
            @arguments[:content_template_path] = @content_template_path
            @arguments[:content_controller] = @context
          end
        end

        # Sometimes we want multiple template bindings to share the same controller (usually
        # when displaying a :Title and a :Body), this instance tracks those.
        if @options && (controller_group = @options[:controller_group])
          @grouped_controller = GroupedControllers.new(controller_group)
        else
          clear_grouped_controller
        end

        full_path, controller_path = @view_lookup.path_for_template(path, section)

        new_controller, new_action = create_controller(full_path, controller_path)

        remove_waiting_controller(new_controller, new_action)

        # Wait until the controller is loaded before we actually render.
        @waiting_for_load = -> { new_controller.loaded? }.watch_until!(true) do
          begin
            # Remove existing template and call _removed
            ControllerLifecycle.call_action(@controller, @action, :"#{@action}_removed") if @action && @controller
            if @current_template
              @current_template.remove
              @current_template = nil
            end

            @controller = new_controller
            @action = new_action

            @waiting_for_load = nil
            render_template(full_path)

            queue_clear_grouped_controller
          rescue => e
            puts "GOT ERR: #{e.inspect}"
          end
        end
      end
    end

    def remove_waiting_controller(new_controller, new_action)
      # Clear any previously running wait for loads.  This is for when the path changes
      # before the view actually renders.
      if @waiting_for_load
        @waiting_for_load.stop

        # Only call the after_..._removed because the dom never loaded.
        ControllerLifecycle.call_action(new_controller, new_action, :"after_#{new_action}_removed")
      end
    end

    # On the next tick, we clear the grouped controller so that any changes to template paths
    # will create a new controller and trigger the action.
    def queue_clear_grouped_controller
      if Volt.in_browser?
        # In the browser, we want to keep a grouped controller around during a single run
        # of the event loop.  To make that happen, we clear it on the next tick.
        `setImmediate(function() {`
        clear_grouped_controller
        `});`
      else
        # For the backend, clear it immediately
        clear_grouped_controller
      end
    end

    def clear_grouped_controller
      if @grouped_controller
        @grouped_controller.clear
        @grouped_controller = nil
      end
    end

    # Create controller loads up the controller for the paths
    def create_controller(full_path, controller_path)
      # If arguments is nil, then an blank SubContext will be created
      args = [SubContext.new(@arguments, nil, true)]

      controller = nil

      # Fetch grouped controllers if we're grouping
      controller = @grouped_controller.get if @grouped_controller

      # The action to be called and rendered
      action     = nil

      if controller
        # Track that we're using the group controller
        @grouped_controller.inc if @grouped_controller
      else
        # Otherwise, make a new controller
        controller_class, action = get_controller(controller_path)

        if controller_class
          # Setup the controller
          controller = controller_class.new(*args)
        else
          controller = ModelController.new(*args)
        end

        # Trigger the action
        ControllerLifecycle.call_action(controller, action) if action

        # Track the grouped controller
        @grouped_controller.set(controller) if @grouped_controller
      end

      return controller, action
    end

    # The context for templates can be either a controller, or the original context.
    def render_template(full_path)
      @current_template = TemplateRenderer.new(@page, @target, @controller, @binding_name, full_path)

      call_ready
    end

    def call_ready
      if @controller
        # Set the current section on the controller if it wants so it can manipulate
        # the dom if needed
        # Only assign sections for action's, so we don't get AttributeSections bound
        # also.
        if @action && @controller.respond_to?(:section=)
          @controller.section = @current_template.dom_section
        end

        # Call the ready callback on the controller
        ControllerLifecycle.call_action(@controller, @action, "#{@action}_ready") if @action
      end
    end

    # Called when the binding is removed from the page
    def remove
      @computation.stop
      @computation = nil

      # TODO: Remove any waiting controllers

      ControllerLifecycle.call_action(@controller, @action, :"before_#{@action}_remove") if @controller && @action

      clear_grouped_controller

      if @current_template
        # Remove the template if one has been rendered, when the template binding is
        # removed.
        @current_template.remove
      end

      super

      if @controller
        ControllerLifecycle.call_action(@controller, @action, :"after_#{@action}_remove") if @action

        @controller = nil
      end
    end

    private
    # Fetch the controller class
    def get_controller(controller_path)
      return nil, nil unless controller_path && controller_path.size > 0

      action = controller_path[-1]

      # Get the constant parts
      parts  = controller_path[0..-2].map { |v| v.tr('-', '_').camelize }

      # Do const lookups starting at object and working our way down.
      # So Volt::ProgressBar would lookup Volt, then ProgressBar on Volt.
      obj = Object
      parts.each do |part|
        if obj.const_defined?(part)
          obj = obj.const_get(part)
        else
          return nil
        end
      end

      [obj, action]
    end
  end
end
