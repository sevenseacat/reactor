defmodule Reactor.Builder.Step do
  @moduledoc """
  Handle building and adding steps to Reactors for the builder.

  You should not use this module directly, but instead use
  `Reactor.Builder.new_step/4` and `Reactor.Builder.add_step/5`.
  """
  alias Reactor.{Argument, Builder, Step, Template}
  import Reactor.Argument, only: :macros
  import Reactor.Utils
  import Reactor.Builder.Argument

  @doc """
  Build and add a new step to a Reactor.
  """
  @spec add_step(
          Reactor.t(),
          any,
          Builder.impl(),
          [Builder.step_argument()],
          Builder.step_options()
        ) :: {:ok, Reactor.t()} | {:error, any}
  def add_step(reactor, name, impl, arguments, options) do
    with {:ok, arguments} <- assert_all_are_arguments(arguments),
         {:ok, arguments} <- maybe_rewrite_input_arguments(reactor, arguments),
         :ok <- assert_is_step_impl(impl),
         {:ok, {arguments, argument_transform_steps}} <-
           build_argument_transform_steps(arguments, name),
         {:ok, arguments, step_transform_step} <-
           maybe_build_step_transform_all_step(arguments, name, options[:transform]),
         {:ok, async} <- validate_async_option(options),
         {:ok, context} <- validate_context_option(options),
         {:ok, max_retries} <- validate_max_retries_option(options) do
      context =
        if step_transform_step do
          deep_merge(context, %{private: %{replace_arguments: :value}})
        else
          context
        end

      steps =
        [
          %Step{
            arguments: arguments,
            async?: async,
            context: context,
            impl: impl,
            name: name,
            max_retries: max_retries,
            ref: make_ref()
          }
        ]
        |> Enum.concat(argument_transform_steps)
        |> maybe_append(step_transform_step)
        |> Enum.concat(reactor.steps)

      {:ok, %{reactor | steps: steps}}
    end
  end

  @doc """
  Dynamically build a new step for later use.

  You're most likely to use this when dynamically returning new steps from an
  existing step.
  """
  @spec new_step(any, Builder.impl(), [Builder.step_argument()], Builder.step_options()) ::
          {:ok, Step.t()} | {:error, any}
  def new_step(name, impl, arguments, options) do
    with {:ok, arguments} <- assert_all_are_arguments(arguments),
         :ok <- assert_no_argument_transforms(arguments),
         :ok <- assert_is_step_impl(impl),
         {:ok, async} <- validate_async_option(options),
         {:ok, context} <- validate_context_option(options),
         {:ok, max_retries} <- validate_max_retries_option(options),
         :ok <- validate_no_transform_option(options) do
      step = %Step{
        arguments: arguments,
        async?: async,
        context: context,
        impl: impl,
        name: name,
        max_retries: max_retries,
        ref: make_ref()
      }

      {:ok, step}
    end
  end

  defp validate_async_option(options) do
    options
    |> Keyword.get(:async?, true)
    |> case do
      value when is_boolean(value) ->
        {:ok, value}

      value ->
        {:error, argument_error(:options, "Invalid value for the `async?` option.", value)}
    end
  end

  defp validate_context_option(options) do
    options
    |> Keyword.get(:context, %{})
    |> case do
      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error,
         argument_error(:options, "Invalid value for the `context` option: must be a map.", value)}
    end
  end

  defp validate_max_retries_option(options) do
    options
    |> Keyword.get(:max_retries, 100)
    |> case do
      :infinity ->
        {:ok, :infinity}

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      value ->
        {:error,
         argument_error(
           :options,
           "Invalid value for the `max_retries` option: must be a non-negative integer or `:infinity`.",
           value
         )}
    end
  end

  defp validate_no_transform_option(options) do
    if Keyword.has_key?(options, :transform) do
      {:error,
       argument_error(:options, "Adding transforms to dynamic steps is not supported.", options)}
    else
      :ok
    end
  end

  defp maybe_rewrite_input_arguments(reactor, arguments) do
    existing_step_names = MapSet.new(reactor.steps, & &1.name)

    map_while_ok(arguments, fn
      argument when is_from_input(argument) ->
        potential_rewrite_step_name = {:__reactor__, :transform, :input, argument.source.name}

        if MapSet.member?(existing_step_names, potential_rewrite_step_name) do
          {:ok, Argument.from_result(argument.name, potential_rewrite_step_name)}
        else
          {:ok, argument}
        end

      argument when is_from_result(argument) or is_from_value(argument) ->
        {:ok, argument}
    end)
  end

  defp assert_is_step_impl({impl, opts}) when is_list(opts), do: assert_is_step_impl(impl)

  defp assert_is_step_impl(impl) when is_atom(impl) do
    if Spark.implements_behaviour?(impl, Step) do
      :ok
    else
      {:error,
       argument_error(:impl, "Module does not implement the `Reactor.Step` behaviour.", impl)}
    end
  end

  defp build_argument_transform_steps(arguments, step_name) do
    arguments
    |> reduce_while_ok({[], []}, fn
      argument, {arguments, steps} when is_from_input(argument) and has_transform(argument) ->
        transform_step_name = {:__reactor__, :transform, argument.name, step_name}

        step =
          build_transform_step(
            argument.source,
            transform_step_name,
            argument.transform
          )

        argument = %Argument{
          name: argument.name,
          source: %Template.Result{name: transform_step_name}
        }

        {:ok, {[argument | arguments], [%{step | transform: nil} | steps]}}

      argument, {arguments, steps} when is_from_result(argument) and has_transform(argument) ->
        transform_step_name = {:__reactor__, :transform, argument.name, step_name}

        step =
          build_transform_step(
            argument.source,
            transform_step_name,
            argument.transform
          )

        argument = %Argument{
          name: argument.name,
          source: %Template.Result{name: transform_step_name}
        }

        {:ok, {[argument | arguments], [%{step | transform: nil} | steps]}}

      argument, {arguments, steps} ->
        {:ok, {[argument | arguments], steps}}
    end)
  end

  defp maybe_build_step_transform_all_step(arguments, _name, nil), do: {:ok, arguments, nil}

  defp maybe_build_step_transform_all_step(arguments, name, transform)
       when is_function(transform, 1),
       do:
         maybe_build_step_transform_all_step(arguments, name, {Step.TransformAll, fun: transform})

  defp maybe_build_step_transform_all_step(arguments, name, transform) do
    step = %Step{
      arguments: arguments,
      async?: true,
      impl: transform,
      name: {:__reactor__, :transform, name},
      max_retries: 0,
      ref: make_ref()
    }

    {:ok, [Argument.from_result(:value, step.name)], step}
  end

  defp build_transform_step(argument_source, step_name, transform) when is_function(transform, 1),
    do: build_transform_step(argument_source, step_name, {Step.Transform, fun: transform})

  defp build_transform_step(argument_source, step_name, transform)
       when tuple_size(transform) == 2 and is_atom(elem(transform, 0)) and
              is_list(elem(transform, 1)) do
    %Step{
      arguments: [
        %Argument{
          name: :value,
          source: argument_source
        }
      ],
      async?: true,
      impl: transform,
      name: step_name,
      max_retries: 0,
      ref: make_ref()
    }
  end

  defp assert_no_argument_transforms(arguments) do
    arguments
    |> Enum.reject(&is_nil(&1.transform))
    |> case do
      [] ->
        :ok

      [argument] ->
        {:error,
         argument_error(
           :arguments,
           "Argument `#{argument.name}` has a transform attached.",
           argument
         )}

      arguments ->
        sentence = sentence(arguments, &"`#{&1.name}`", ", ", " and ")

        {:error,
         argument_error(:arguments, "Arguments #{sentence} have transforms attached.", arguments)}
    end
  end
end
