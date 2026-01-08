defmodule Oaskit.Validation.BodyNormalizerTest do
  use ExUnit.Case, async: true

  alias Oaskit.Validation.BodyNormalizer

  describe "normalize/4" do
    setup do
      # Build a test schema with bracket array properties
      schema = %{
        "type" => "object",
        "properties" => %{
          "texts[]" => %{"type" => "array", "items" => %{"type" => "string"}},
          "name" => %{"type" => "string"},
          "nested" => %{
            "type" => "object",
            "properties" => %{
              "tags[]" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          "items" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "ids[]" => %{"type" => "array", "items" => %{"type" => "integer"}}
              }
            }
          }
        }
      }

      jsv_ctx = JSV.build_init!()
      {_ns, _, jsv_ctx} = JSV.build_add!(jsv_ctx, schema)
      {jsv_key, jsv_ctx} = JSV.build_key!(jsv_ctx, JSV.Ref.pointer!([], :root))
      jsv_root = JSV.to_root!(jsv_ctx, :root)

      %{jsv_key: jsv_key, jsv_root: jsv_root}
    end

    test "transforms bracket-less keys to bracket keys for multipart/form-data", ctx do
      body_params = %{"texts" => ["a", "b"], "name" => "test"}
      content_type = {"multipart", "form-data"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{"texts[]" => ["a", "b"], "name" => "test"}
    end

    test "transforms bracket-less keys to bracket keys for application/x-www-form-urlencoded",
         ctx do
      body_params = %{"texts" => ["a", "b"], "name" => "test"}
      content_type = {"application", "x-www-form-urlencoded"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{"texts[]" => ["a", "b"], "name" => "test"}
    end

    test "passes through unchanged for application/json", ctx do
      body_params = %{"texts" => ["a", "b"], "name" => "test"}
      content_type = {"application", "json"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{"texts" => ["a", "b"], "name" => "test"}
    end

    test "passes through unchanged for other content types", ctx do
      body_params = %{"texts" => ["a", "b"]}
      content_type = {"text", "plain"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{"texts" => ["a", "b"]}
    end

    test "recursively normalizes nested objects", ctx do
      body_params = %{
        "name" => "test",
        "nested" => %{"tags" => ["tag1", "tag2"]}
      }

      content_type = {"multipart", "form-data"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{
               "name" => "test",
               "nested" => %{"tags[]" => ["tag1", "tag2"]}
             }
    end

    test "recursively normalizes arrays of objects", ctx do
      body_params = %{
        "items" => [
          %{"ids" => [1, 2, 3]},
          %{"ids" => [4, 5]}
        ]
      }

      content_type = {"multipart", "form-data"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{
               "items" => [
                 %{"ids[]" => [1, 2, 3]},
                 %{"ids[]" => [4, 5]}
               ]
             }
    end

    test "handles empty body params", ctx do
      body_params = %{}
      content_type = {"multipart", "form-data"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{}
    end

    test "preserves non-bracket keys unchanged", ctx do
      body_params = %{"name" => "test", "unknown" => "value"}
      content_type = {"multipart", "form-data"}

      result = BodyNormalizer.normalize(body_params, content_type, ctx.jsv_key, ctx.jsv_root)

      assert result == %{"name" => "test", "unknown" => "value"}
    end
  end

  describe "normalize_bracket_arrays/2" do
    test "transforms bracket-less keys to bracket keys" do
      props_map = %{
        "texts[]" => %JSV.Subschema{validators: [], schema_path: [], cast: nil},
        "name" => %JSV.Subschema{validators: [], schema_path: [], cast: nil}
      }

      body_params = %{"texts" => ["a", "b"], "name" => "test"}

      result = BodyNormalizer.normalize_bracket_arrays(body_params, props_map)

      assert result == %{"texts[]" => ["a", "b"], "name" => "test"}
    end

    test "handles nil props_map" do
      body_params = %{"texts" => ["a", "b"]}

      result = BodyNormalizer.normalize_bracket_arrays(body_params, nil)

      assert result == %{"texts" => ["a", "b"]}
    end

    test "handles non-map body_params" do
      props_map = %{"texts[]" => %JSV.Subschema{validators: [], schema_path: [], cast: nil}}

      result = BodyNormalizer.normalize_bracket_arrays("not a map", props_map)

      assert result == "not a map"
    end

    test "prioritizes exact match over bracket mapping when both exist" do
      # If schema has both "texts" and "texts[]", incoming "texts" should match "texts"
      props_map = %{
        "texts" => %JSV.Subschema{validators: [], schema_path: [], cast: nil},
        "texts[]" => %JSV.Subschema{validators: [], schema_path: [], cast: nil}
      }

      body_params = %{"texts" => "single value"}

      result = BodyNormalizer.normalize_bracket_arrays(body_params, props_map)

      # Should NOT be transformed since "texts" exists in schema
      assert result == %{"texts" => "single value"}
    end
  end
end
