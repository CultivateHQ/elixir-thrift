defmodule Thrift.Generator.StructGenerator do
  alias Thrift.Generator.StructBinaryProtocol
  alias Thrift.Generator.Utils
  alias Thrift.Parser.FileGroup
  alias Thrift.Parser.Models.{
    Exception,
    Field,
    Struct,
    TypeRef,
    TEnum,
    Union,
  }

  def generate(label, schema, name, struct) when label in [:struct, :union, :exception] do
    struct_parts = Enum.map(struct.fields, fn
      %Field{name: name, type: type, default: default} ->
        {name, Utils.quote_value(default, type, schema)}
    end)

    binary_protocol_defs = [
      StructBinaryProtocol.struct_serializer(struct, name, schema.file_group),
      StructBinaryProtocol.struct_deserializer(struct, name, schema.file_group),
    ]
    |> Utils.merge_blocks
    |> Utils.sort_defs

    define_block = case label do
      :struct ->
        quote do: defstruct unquote(struct_parts)
      :union ->
        quote do: defstruct unquote(struct_parts)
      :exception ->
        quote do: defexception unquote(struct_parts)
    end

    quote do
      defmodule unquote(name) do
        _ = unquote "Auto-generated Thrift #{label} #{struct.name}"
        unquote_splicing(for field <- struct.fields do
          quote do
            _ = unquote "#{field.id}: #{to_thrift(field.type, schema.file_group)} #{field.name}"
          end
        end)
        unquote(define_block)
        @type t :: %__MODULE__{}
        def new, do: %__MODULE__{}
        defmodule BinaryProtocol do
          unquote_splicing(binary_protocol_defs)
        end
        def serialize(struct) do
          BinaryProtocol.serialize(struct)
        end
        def serialize(struct, :binary) do
          BinaryProtocol.serialize(struct)
        end
        def deserialize(binary) do
          BinaryProtocol.deserialize(binary)
        end
      end
    end
  end

  def to_thrift(base_type, _file_group) when is_atom(base_type) do
    Atom.to_string(base_type)
  end
  def to_thrift({:map, {key_type, val_type}}, file_group) do
    "map<#{to_thrift key_type, file_group},#{to_thrift val_type, file_group}>"
  end
  def to_thrift({:set, element_type}, file_group) do
    "set<#{to_thrift element_type, file_group}>"
  end
  def to_thrift({:list, element_type}, file_group) do
    "list<#{to_thrift element_type, file_group}>"
  end
  def to_thrift(%TEnum{name: name}, _file_group) do
    "#{name}"
  end
  def to_thrift(%Struct{name: name}, _file_group) do
    "#{name}"
  end
  def to_thrift(%Exception{name: name}, _file_group) do
    "#{name}"
  end
  def to_thrift(%Union{name: name}, _file_group) do
    "#{name}"
  end
  def to_thrift(%TypeRef{referenced_type: type}, file_group) do
    FileGroup.resolve(file_group, type) |> to_thrift(file_group)
  end
end
