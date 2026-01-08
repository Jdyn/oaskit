defmodule Oaskit.Validation.BodyNormalizer do
  @moduledoc """
  Normalizes request body params for form-based content types.

  Handles the bracket notation mismatch between HTML form arrays
  (parsed by Phoenix as "field" => [...]) and OpenAPI schemas
  (which define properties as "field[]").

  ## Problem

  When an HTML form uses bracket notation for array inputs:

      <input type="file" name="texts[]" multiple>

  Phoenix's `Plug.Conn.Query.decode` strips the brackets when parsing:

      # Input: texts[]=hello&texts[]=world
      # Result: %{"texts" => ["hello", "world"]}

  But OpenAPI schemas define the property with brackets:

      %{properties: %{"texts[]" => %{type: :array, items: ...}}}

  This module normalizes the parsed body params to match the schema's
  expected property names by mapping bracket-less keys back to their
  bracket-suffixed equivalents.
  """

  @form_content_types [
    {"multipart", "form-data"},
    {"application", "x-www-form-urlencoded"}
  ]

  @doc """
  Normalizes body params by mapping bracket-less keys to their
  bracket-suffixed schema equivalents for form-based requests.

  Returns the original body params unchanged for other content types.

  ## Parameters

    * `body_params` - The parsed body parameters from the request
    * `content_type` - A tuple of `{primary, secondary}` content type parts
    * `jsv_key` - The JSV schema key for the request body
    * `jsv_root` - The JSV root containing all validators

  ## Examples

      # For multipart/form-data with schema expecting "texts[]"
      normalize(%{"texts" => ["a", "b"]}, {"multipart", "form-data"}, jsv_key, jsv_root)
      # => %{"texts[]" => ["a", "b"]}

      # For application/json, no transformation
      normalize(%{"texts" => ["a", "b"]}, {"application", "json"}, jsv_key, jsv_root)
      # => %{"texts" => ["a", "b"]}
  """
  @spec normalize(map, {binary, binary}, term, term) :: map
  def normalize(body_params, content_type, jsv_key, jsv_root)

  def normalize(body_params, content_type, jsv_key, jsv_root)
      when is_map(body_params) and content_type in @form_content_types do
    case fetch_subschema(jsv_key, jsv_root) do
      {:ok, subschema} ->
        normalize_with_subschema(body_params, subschema)

      :error ->
        body_params
    end
  end

  def normalize(body_params, _content_type, _jsv_key, _jsv_root) do
    body_params
  end

  @doc false
  def normalize_with_subschema(body_params, subschema) when is_map(body_params) do
    props_map = extract_props_map(subschema)
    normalize_bracket_arrays(body_params, props_map)
  end

  def normalize_with_subschema(body_params, _subschema), do: body_params

  @doc false
  def normalize_bracket_arrays(body_params, nil), do: body_params

  def normalize_bracket_arrays(body_params, props_map) when is_map(body_params) and is_map(props_map) do
    bracket_mapping = build_bracket_mapping(props_map)

    Enum.reduce(body_params, %{}, fn {key, value}, acc ->
      str_key = to_string(key)

      {final_key, nested_subschema} =
        cond do
          # Prioritize exact match - if the key exists in schema, use it as-is
          # Check both string and atom versions since schema may use atoms
          Map.has_key?(props_map, key) ->
            {key, Map.get(props_map, key)}

          is_binary(key) and Map.has_key?(props_map, String.to_atom(key)) ->
            {key, Map.get(props_map, String.to_atom(key))}

          # Otherwise, check if there's a bracket mapping
          # bracket_mapping uses string keys
          Map.has_key?(bracket_mapping, str_key) ->
            bracket_key = Map.fetch!(bracket_mapping, str_key)
            {bracket_key, Map.get(props_map, bracket_key)}

          # No match, keep key as-is
          true ->
            {key, nil}
        end

      final_value = normalize_value(value, nested_subschema)
      Map.put(acc, final_key, final_value)
    end)
  end

  def normalize_bracket_arrays(body_params, _props_map), do: body_params

  defp normalize_value(value, subschema) when is_map(value) do
    case extract_props_map(subschema) do
      nil -> value
      props_map -> normalize_bracket_arrays(value, props_map)
    end
  end

  defp normalize_value(values, subschema) when is_list(values) do
    case extract_items_subschema(subschema) do
      nil ->
        values

      items_subschema ->
        Enum.map(values, &normalize_value(&1, items_subschema))
    end
  end

  defp normalize_value(value, _subschema), do: value

  defp build_bracket_mapping(props_map) do
    props_map
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(to_string(&1), "[]"))
    |> Map.new(fn bracket_key ->
      base_key = String.trim_trailing(to_string(bracket_key), "[]")
      {base_key, bracket_key}
    end)
  end

  defp fetch_subschema(jsv_key, jsv_root) do
    case Map.fetch(jsv_root.validators, jsv_key) do
      {:ok, %JSV.Subschema{} = subschema} -> {:ok, subschema}
      _ -> :error
    end
  end

  defp extract_props_map(nil), do: nil

  defp extract_props_map(%JSV.Subschema{validators: validators}) do
    Enum.find_value(validators, fn
      {JSV.Vocabulary.V202012.Applicator, opts} ->
        case Keyword.get(opts, :"jsv@props") do
          {props_map, _, _} when is_map(props_map) -> props_map
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp extract_props_map(_), do: nil

  defp extract_items_subschema(nil), do: nil

  defp extract_items_subschema(%JSV.Subschema{validators: validators}) do
    Enum.find_value(validators, fn
      {JSV.Vocabulary.V202012.Applicator, opts} ->
        case Keyword.get(opts, :"jsv@array") do
          {%JSV.Subschema{} = items_subschema, _} -> items_subschema
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp extract_items_subschema(_), do: nil
end
