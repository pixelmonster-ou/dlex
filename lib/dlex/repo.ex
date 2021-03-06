defmodule Dlex.Repo do
  @moduledoc """
  Ecto-like repository, which allows to embed the schema

    defmodule Repo do
      use Dlex.Repo, otp_app: :my_app, modules: [User]
    end

    config :my_app, Repo,
      hostname: "localhost",
      port: 3306
  """
  alias Dlex.{Repo.Meta, Utils}

  @doc """

  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      @name opts[:name] || __MODULE__
      @meta_name :"#{@name}.Meta"
      @otp_app opts[:otp_app]
      @modules opts[:modules] || []

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        start_opts = %{
          module: __MODULE__,
          otp_app: @otp_app,
          name: @name,
          meta_name: @meta_name,
          modules: @modules,
          opts: opts
        }

        Dlex.Repo.Sup.start_link(start_opts)
      end

      def set(node, opts \\ []), do: Dlex.Repo.set(@name, node, opts)
      def set!(node, opts \\ []), do: Dlex.Repo.set!(@name, node, opts)

      def mutate(node, opts \\ []), do: Dlex.Repo.mutate(@name, node, opts)
      def mutate!(node, opts \\ []), do: Dlex.Repo.mutate!(@name, node, opts)

      def get(uid), do: Dlex.Repo.get(@name, meta(), uid)
      def get!(uid), do: Dlex.Repo.get!(@name, meta(), uid)
      def get_raw(uid), do: Dlex.Repo.get_raw(@name, meta(), uid)
      def get_raw!(uid), do: Dlex.Repo.get_raw!(@name, meta(), uid)

      def all(query), do: Dlex.Repo.all(@name, query, meta())

      def meta(), do: Dlex.Repo.Meta.get(@meta_name)
      def register(modules), do: Dlex.Repo.Meta.register(@meta_name, modules)
      def snapshot(), do: Dlex.Repo.snapshot(@meta_name)
      def alter_schema(snapshot \\ snapshot()), do: Dlex.Repo.alter_schema(@name, snapshot)

      def stop(timeout \\ 5000), do: Supervisor.stop(@name, :normal, timeout)

      def drop_all(), do: Dlex.Repo.drop_all(@name)
    end
  end

  @doc false
  def child_spec(%{module: module, otp_app: otp_app, name: name, opts: opts}) do
    opts = Keyword.merge(opts, Application.get_env(otp_app, module, []))
    Dlex.child_spec([{:name, name} | opts])
  end

  @doc """
  Build or update lookup map from module list
  """
  def build_lookup_map(lookup_map \\ %{}, modules) do
    for module <- List.wrap(modules), reduce: lookup_map do
      acc ->
        case source(module) do
          nil -> acc
          source -> Map.put(acc, source, module)
        end
    end
  end

  @doc """
  Query all. It automatically tries to decode values inside of a query. To make it work, you
  need to expand the results it like this: `uid dgraph.type expand(_all_)`
  """
  def all(conn, query, %{lookup: lookup} = _meta \\ %{lookup: %{}}) do
    with {:ok, data} <- Dlex.query(conn, query), do: decode(data, lookup, false)
  end

  def set!(conn, data, opts), do: mutate!(conn, data, opts)

  @doc """
  The same as `mutate`.
  """
  def set(conn, data, opts), do: mutate(conn, data, opts)

  @doc """
  The same as `mutate/2`, but return result of sucessful operation or raises.
  """
  def mutate!(conn, data, opts) do
    case mutate(conn, data, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Mutate data
  """
  def mutate(conn, %{__struct__: Ecto.Changeset, changes: changes, data: %type{uid: uid}}, opts) do
    data = struct(type, Map.put(changes, :uid, uid))
    mutate(conn, data, opts)
  end

  def mutate(conn, data, opts) do
    data_with_ids = Utils.add_blank_ids(data, :uid)

    with {:ok, ids_map} <- Dlex.mutate(conn, %{}, encode(data_with_ids), opts) do
      {:ok, Utils.replace_ids(data_with_ids, ids_map, :uid)}
    end
  end

  def encode(%{__struct__: struct} = data) do
    data
    |> Map.from_struct()
    |> Enum.flat_map(&encode_kv(&1, struct))
    |> Map.new()
  end

  def encode(data) when is_list(data), do: Enum.map(data, &encode/1)
  def encode(data), do: data

  defp encode_kv({_key, nil}, _), do: []

  defp encode_kv({:uid, value}, struct),
    do: [{"uid", value}, {"dgraph.type", source(struct)}]

  defp encode_kv({key, value}, struct) do
    case field(struct, key) do
      nil ->
        []

      string_key ->
        case type(struct, key) do
          :relation ->
            [{string_key, value |> from_relation()}]

          :relations ->
            [{string_key, value |> Enum.map(&from_relation/1)}]

          :lang ->
            value |> from_lang(string_key)

          _ ->
            [{string_key, encode(value)}]
        end
    end
  end

  defp from_lang(list, key) when is_list(list),
    do: list |> Enum.map(&from_lang(&1, key)) |> List.flatten()

  defp from_lang(%Dlex.Lang{language: language, value: value}, key)
       when is_bitstring(value) and is_bitstring(language) do
    [{"#{key}@#{language}", value}]
  end

  defp from_lang(%Ecto.Changeset{action: action} = changeset, key) do
    {:ok, struct} = Ecto.Changeset.apply_action(changeset, action)

    struct
    |> from_lang(key)
  end

  defp from_relation(val) when is_binary(val), do: %{uid: val}
  defp from_relation(val), do: val

  @compile {:inline, field: 2}
  def field(_struct, "uid"), do: {:uid, :string}
  def field(struct, key), do: struct.__schema__(:field, key)
  @compile {:inline, type: 2}
  def type(struct, key), do: struct.__schema__(:type, key)
  @compile {:inline, source: 1}
  def source(struct), do: struct.__schema__(:source)

  @doc """
  The same as `get/3`, but return result or raises.
  """
  def get!(conn, meta, uid) do
    case get(conn, meta, uid) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Get by uid
  """
  def get(conn, %{lookup: lookup} = meta, uid) do
    langs =
      Map.get(meta, :modules, [])
      |> Enum.map(&grab_all_langs/1)
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.join(" ")
      |> String.trim()

    statement = [
      "{uid_get(func: uid(",
      uid,
      ")) {uid dgraph.type #{langs} expand(_all_) { uid dgraph.type #{langs} expand(_all_) { uid dgraph.type #{
        langs
      } expand(_all_)}}}}"
    ]

    with {:ok, %{"uid_get" => nodes}} <- Dlex.query(conn, statement) do
      case nodes do
        [%{"uid" => _, "dgraph.type" => types} = map] when map_size(map) < 2 and types != [] ->
          {:ok, nil}

        [map] ->
          decode(map, lookup)
      end
    end
  end

  @doc """
  The same as `get_raw/3`, but return result or raises.
  """
  def get_raw!(conn, meta, uid) do
    case get_raw(conn, meta, uid) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Get an item by uid but doesn't turn it into a node
  """
  def get_raw(conn, meta, uid) do
    langs =
      Map.get(meta, :modules, [])
      |> Enum.map(&grab_all_langs/1)
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.join(" ")
      |> String.trim()

    statement = [
      "{uid_get(func: uid(",
      uid,
      ")) {uid dgraph.type #{langs} expand(_all_) { uid dgraph.type #{langs} expand(_all_)}}}"
    ]

    with {:ok, %{"uid_get" => nodes}} <- Dlex.query(conn, statement) do
      case nodes do
        [%{"uid" => _} = map] when map_size(map) <= 2 -> {:ok, nil}
        [map] -> {:ok, map}
      end
    end
  end

  def grab_all_langs(nil), do: ""

  def grab_all_langs(model) do
    model.__schema__(:field_types)
    |> Enum.filter(fn {_, _, type} -> type == :lang end)
    |> Enum.map(fn {_, field, _} ->
      "#{field}@*"
    end)
  end

  @doc """
  Decode resulting map to a structure.
  """
  def decode(map, lookup, strict? \\ true) do
    {:ok, do_decode(map, lookup, strict?)}
  catch
    {:error, error} -> {:error, error}
  end

  defp do_decode(map, lookup, strict?) when is_map(map) and is_map(lookup) do
    with %{"dgraph.type" => [type_string]} <- map,
         type when type != nil <- Map.get(lookup, type_string) do
      do_decode_map(map, type, lookup, strict?)
    else
      _ ->
        cond do
          strict? ->
            {:error, {:untyped, map}}

          true ->
            for {key, values} <- map, into: %{}, do: {key, do_decode(values, lookup, strict?)}
        end
    end
  end

  defp do_decode(list, lookup, strict?) when is_list(list) and is_map(lookup) do
    for value <- list, do: do_decode(value, lookup, strict?)
  end

  defp do_decode(value, _lookup, _strict?), do: value

  defp do_decode_map(map, type, lookup, strict?) when is_map(map) and is_atom(type) do
    Enum.reduce(map, type.__struct__(), fn {key, value}, struct ->
      do_decode_field(
        struct,
        lang?(String.split(key, "@"), key, type),
        value,
        lookup,
        strict?
      )
    end)
  end

  defp lang?([key, lang], _original, type), do: {field(type, key), lang}
  defp lang?(_, original, type), do: field(type, original)

  defp do_decode_field(struct, {{key, _}, lang}, value, _lookup, _strict?) do
    is_list(value)
    |> case do
      true -> Ecto.Type.cast(:string, List.first(value))
      false -> Ecto.Type.cast(:string, value)
    end
    |> case do
      {:ok, casted_value} ->
        merge_list(
          struct,
          key,
          casted_value |> into_lang_struct(lang)
        )

      {:error, error} ->
        throw({:error, error})
    end
  end

  defp do_decode_field(struct, {field_name, field_type}, value, lookup, strict?) do
    case Ecto.Type.cast(ecto_type?(field_type), value) do
      {:ok, casted_value} -> Map.put(struct, field_name, do_decode(casted_value, lookup, strict?))
      {:error, error} -> throw({:error, error})
    end
  end

  defp do_decode_field(struct, nil, _value, _lookup, _strict?), do: struct

  defp into_lang_struct(value, language), do: %Dlex.Lang{language: language, value: value}

  defp merge_list(map, key, add) do
    map
    |> Map.put(key, [add | Map.get(map, key, [])] |> Enum.uniq())
  end

  defp ecto_type?(:relation), do: :map
  defp ecto_type?(:relations), do: {:array, :any}
  defp ecto_type?(:reverse_relation), do: {:array, :map}
  defp ecto_type?(field_type), do: field_type

  def get_by(conn, field, name) do
    statement = "query all($a: string) {all(func: eq(#{field}, $a)) {uid expand(_all_)}}"
    with %{"all" => [obj]} <- Dlex.query!(conn, statement, %{"$a" => name}), do: obj
  end

  @doc """
  Alter schema for modules
  """
  def alter_schema(conn, snapshot) do
    with {:ok, sch} <- Dlex.query_schema(conn), do: do_alter_schema(conn, sch, snapshot)
  end

  defp do_alter_schema(conn, %{"schema" => schema, "types" => types}, snapshot) do
    delta = %{
      "schema" => snapshot["schema"] -- schema,
      "types" => snapshot["types"] -- types
    }

    delta_l = length(delta["schema"]) + length(delta["types"])

    case delta do
      %{"schema" => [], "types" => []} -> {:ok, 0}
      alter -> with {:ok, _} <- Dlex.alter(conn, %{schema: alter}), do: {:ok, delta_l}
    end
  end

  defp do_alter_schema(conn, sch, snapshot) do
    do_alter_schema(conn, Map.put_new(sch, "types", []), snapshot)
  end

  @doc """
  Generate snapshot for running meta process
  """
  def snapshot(meta) do
    %{modules: modules} = Meta.get(meta)

    modules
    |> MapSet.to_list()
    |> List.wrap()
    |> expand_modules()
    |> Enum.map(& &1.__schema__(:alter))
    |> Enum.reduce(%{"types" => [], "schema" => []}, fn mod_sch, acc ->
      %{
        "types" => Enum.concat(acc["types"], mod_sch["types"]),
        "schema" => Enum.concat(acc["schema"], mod_sch["schema"])
      }
    end)
  end

  defp expand_modules(modules) do
    Enum.reduce(modules, modules, fn module, modules ->
      depends_on_modules = module.__schema__(:depends_on)
      Enum.reduce(depends_on_modules, modules, &if(Enum.member?(&2, &1), do: &2, else: [&1 | &2]))
    end)
  end

  @doc """
  Drop everything from database. Use with caution, as it deletes everything, what you have
  in database.
  """
  def drop_all(conn) do
    Dlex.alter(conn, %{drop_all: true})
  end
end
