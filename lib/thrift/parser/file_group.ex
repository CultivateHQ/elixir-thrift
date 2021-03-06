defmodule Thrift.Parser.FileGroup do
  @moduledoc """
  Represents a group of parsed files.

  When you parse a file, it might include other thrift files. These files are
  in turn accumulated and parsed and added to this module. Additionally, this
  module allows resolution of the names of Structs / Enums / Unions etc across
  files.
  """

  alias Thrift.Parser

  alias Thrift.Parser.{
    FileGroup,
    FileRef,
    ParsedFile,
    Resolver
  }

  alias Thrift.AST.{
    Constant,
    Exception,
    Field,
    Namespace,
    Schema,
    Service,
    Struct,
    TEnum,
    TypeRef,
    Union,
    ValueRef
  }

  @type t :: %FileGroup{
          initial_file: Path.t(),
          parsed_files: %{FileRef.thrift_include() => %ParsedFile{}},
          schemas: %{FileRef.thrift_include() => %Schema{}},
          ns_mappings: %{atom => %Namespace{}},
          opts: Parser.opts()
        }

  @enforce_keys [:initial_file, :opts]
  defstruct initial_file: nil,
            parsed_files: %{},
            schemas: %{},
            resolutions: %{},
            immutable_resolutions: %{},
            ns_mappings: %{},
            opts: Keyword.new()

  @spec new(Path.t(), Parser.opts()) :: t
  def new(initial_file, opts \\ []) do
    %FileGroup{initial_file: initial_file, opts: opts}
  end

  @spec add(t, ParsedFile.t()) :: t
  def add(file_group, parsed_file) do
    file_group = add_includes(file_group, parsed_file)
    new_parsed_files = Map.put(file_group.parsed_files, parsed_file.name, parsed_file)
    new_schemas = Map.put(file_group.schemas, parsed_file.name, parsed_file.schema)
    resolutions = Resolver.add(file_group.resolutions, parsed_file)

    %__MODULE__{
      file_group
      | parsed_files: new_parsed_files,
        schemas: new_schemas,
        immutable_resolutions: resolutions,
        resolutions: resolutions
    }
  end

  defp add_includes(%FileGroup{} = group, %ParsedFile{schema: schema, file_ref: file_ref}) do
    # Search for included files in the current directory (relative to the
    # parsed file) as well as any additionally configured include paths.
    include_paths = [Path.dirname(file_ref.path) | Keyword.get(group.opts, :include_paths, [])]

    Enum.reduce(schema.includes, group, fn include, group ->
      parsed_file =
        include.path
        |> find_include(include_paths)
        |> FileRef.new()
        |> ParsedFile.new()

      add(group, parsed_file)
    end)
  end

  # Attempt to locate `path` in one of `dirs`, returning the path of the
  # first match on success or the original `path` if not match is found.
  defp find_include(path, dirs) do
    dirs
    |> Enum.map(&Path.join(&1, path))
    |> Enum.find(path, &File.exists?/1)
  end

  @spec set_current_module(t, atom) :: t
  def set_current_module(file_group, module) do
    # since in a file, we can refer to things defined in that file in a non-qualified
    # way, we add unqualified names to the resolutions map.

    current_module = Atom.to_string(module)

    resolutions =
      file_group.immutable_resolutions
      |> Enum.flat_map(fn {name, v} = original_mapping ->
        case String.split(Atom.to_string(name), ".") do
          [^current_module, enum_name, value_name] ->
            [{:"#{enum_name}.#{value_name}", v}, original_mapping]

          [^current_module, rest] ->
            [{:"#{rest}", v}, original_mapping]

          _ ->
            [original_mapping]
        end
      end)
      |> Map.new()

    default_namespace =
      if file_group.opts[:namespace] do
        %Namespace{:name => :elixir, :path => file_group.opts[:namespace]}
      end

    ns_mappings = build_ns_mappings(file_group.schemas, default_namespace)

    %FileGroup{file_group | resolutions: resolutions, ns_mappings: ns_mappings}
  end

  @spec resolve(t, any) :: any
  for type <- Thrift.primitive_names() do
    def resolve(_, unquote(type)), do: unquote(type)
  end

  def resolve(%FileGroup{} = group, %Field{type: type} = field) do
    %Field{field | type: resolve(group, type)}
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, %TypeRef{referenced_type: type_name}) do
    resolve(group, resolutions[type_name])
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, %ValueRef{
        referenced_value: value_name
      }) do
    resolve(group, resolutions[value_name])
  end

  def resolve(%FileGroup{resolutions: resolutions} = group, path)
      when is_atom(path) and not is_nil(path) do
    # this can resolve local mappings like :Weather or
    # remote mappings like :"common.Weather"
    resolve(group, resolutions[path])
  end

  def resolve(%FileGroup{} = group, {:list, elem_type}) do
    {:list, resolve(group, elem_type)}
  end

  def resolve(%FileGroup{} = group, {:set, elem_type}) do
    {:set, resolve(group, elem_type)}
  end

  def resolve(%FileGroup{} = group, {:map, {key_type, val_type}}) do
    {:map, {resolve(group, key_type), resolve(group, val_type)}}
  end

  def resolve(_, other) do
    other
  end

  @spec dest_module(t, any) :: atom
  def dest_module(file_group, %Struct{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Union{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Exception{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %TEnum{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, %Service{name: name}) do
    dest_module(file_group, name)
  end

  def dest_module(file_group, Constant) do
    # Default to naming the constants module after the namespaced, camelized
    # basename of its file. For foo.thrift, this would be `foo.Foo`.
    base = Path.basename(file_group.initial_file, ".thrift")
    default = base <> "." <> Macro.camelize(base)

    # However, if we're already going to generate an equivalent module name
    # (ignoring case), use that instead to avoid generating two modules with
    # the same spellings but different cases.
    schema = file_group.schemas[base]

    symbols =
      [
        Enum.map(schema.enums, fn {_, s} -> s.name end),
        Enum.map(schema.exceptions, fn {_, s} -> s.name end),
        Enum.map(schema.structs, fn {_, s} -> s.name end),
        Enum.map(schema.services, fn {_, s} -> s.name end),
        Enum.map(schema.unions, fn {_, s} -> s.name end)
      ]
      |> List.flatten()
      |> Enum.map(&Atom.to_string/1)

    target = String.downcase(default)
    name = Enum.find(symbols, default, fn s -> String.downcase(s) == target end)

    dest_module(file_group, String.to_atom(name))
  end

  def dest_module(file_group, name) do
    name_parts =
      name
      |> Atom.to_string()
      |> String.split(".", parts: 2)

    module_name = name_parts |> Enum.at(0) |> String.to_atom()
    struct_name = name_parts |> Enum.at(1) |> initialcase

    case file_group.ns_mappings[module_name] do
      nil ->
        Module.concat([struct_name])

      namespace = %Namespace{} ->
        namespace_parts =
          namespace.path
          |> String.split(".")
          |> Enum.map(&Macro.camelize/1)

        Module.concat(namespace_parts ++ [struct_name])
    end
  end

  # Capitalize just the initial character of a string, leaving the rest of the
  # string's characters intact.
  @spec initialcase(String.t()) :: String.t()
  defp initialcase(string) when is_binary(string) do
    {first, rest} = String.next_grapheme(string)
    String.upcase(first) <> rest
  end

  # check if the given model is defined in the root file of the file group
  #   this should eventually be replaced if we find a way to only parse files
  #   once
  @spec own_constant?(t, Constant.t()) :: boolean
  def own_constant?(file_group, %Constant{} = constant) do
    basename = Path.basename(file_group.initial_file, ".thrift")
    initial_file = file_group.parsed_files[basename]
    Enum.member?(Map.keys(initial_file.schema.constants), constant.name)
  end

  defp build_ns_mappings(schemas, default_namespace) do
    schemas
    |> Enum.map(fn {module_name, %Schema{namespaces: ns}} ->
      namespace = Map.get(ns, :elixir, default_namespace)
      {String.to_atom(module_name), namespace}
    end)
    |> Map.new()
  end
end
