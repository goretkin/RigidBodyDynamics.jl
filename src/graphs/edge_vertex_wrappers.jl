# Vertex and Edge types; useful for wrapping an existing type with the edge interface.
# Note that DirectedGraph does not require using these types; just implement the edge interface.
for typename in (:Edge, :Vertex)
    getid = Symbol(lowercase(string(typename)) * "_index")
    setid = Symbol(lowercase(string(typename)) * "_index!")
    @eval begin
        mutable struct $typename{T}
            data::T
            id::Int64

            $typename(data::T) where {T} = new{T}(data, -1)
        end
        data(x::$typename) = x.data
        $getid(x::$typename) = x.id
        $setid(x::$typename, index::Int64) = (x.id = index)
    end
end
