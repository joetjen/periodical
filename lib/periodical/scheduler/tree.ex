defmodule Periodical.Scheduler.Tree do
  @moduledoc false

  # A minimal typed wrapper over Erlang's `:gb_trees`, covering exactly what the
  # queue needs. `:gb_trees` raises on an empty tree, so `smallest/1` reports
  # emptiness as a value instead -- the scheduler asks "what is next?" constantly and
  # an empty schedule set is ordinary, not exceptional.

  @typedoc "An ordered tree of schedule keys to job identifiers."
  @opaque t :: :gb_trees.tree()

  @doc "Returns an empty tree."
  @spec new() :: t()
  def new, do: :gb_trees.empty()

  @doc "Inserts or replaces `key`."
  @spec put(t(), term(), term()) :: t()
  def put(tree, key, value), do: :gb_trees.enter(key, value, tree)

  @doc "Removes `key`, tolerating its absence."
  @spec delete(t(), term()) :: t()
  def delete(tree, key), do: :gb_trees.delete_any(key, tree)

  @doc "Returns how many entries the tree holds."
  @spec size(t()) :: non_neg_integer()
  def size(tree), do: :gb_trees.size(tree)

  @doc "Returns every entry in key order."
  @spec to_list(t()) :: [{term(), term()}]
  def to_list(tree), do: :gb_trees.to_list(tree)

  @doc "Builds a tree from key/value pairs, tolerating unsorted input."
  @spec from_list([{term(), term()}]) :: t()
  def from_list(entries) when is_list(entries) do
    Enum.reduce(entries, new(), fn {key, value}, tree -> put(tree, key, value) end)
  end

  @doc "Returns the lowest-ordered entry, or `:empty`."
  @spec smallest(t()) :: {:ok, {term(), term()}} | :empty
  def smallest(tree) do
    if :gb_trees.is_empty(tree), do: :empty, else: {:ok, :gb_trees.smallest(tree)}
  end
end
