# TODO: use $(SIGNATURES) again once it isn't broken anymore
"""
attach!(mechanism, predecessor, successor, joint; joint_pose, successor_pose)

Attach `successor` to `predecessor` using `joint`.

See [`Joint`](@ref) for definitions of the terms successor and predecessor.

The `Transform3D`s `joint_pose` and `successor_pose` define where
`joint` is attached to each body. `joint_pose` should define
`frame_before(joint)` with respect to any frame fixed to `predecessor`, and likewise
`successor_pose` should define any frame fixed to `successor` with respect to
`frame_after(joint)`.

`predecessor` is required to already be among the bodies of the `Mechanism`.

If `successor` is not yet a part of the `Mechanism`, it will be added to the
`Mechanism`. Otherwise, the `joint` will be treated as a non-tree edge in the
`Mechanism`, effectively creating a loop constraint that will be enforced
using Lagrange multipliers (as opposed to using recursive algorithms).
"""
function attach!(mechanism::Mechanism{T}, predecessor::RigidBody{T}, successor::RigidBody{T}, joint::GenericJoint{T};
        joint_pose::Transform3D = eye(Transform3D{T}, frame_before(joint), default_frame(predecessor)),
        successor_pose::Transform3D = eye(Transform3D{T}, default_frame(successor), frame_after(joint))) where {T}
    @assert joint_pose.from == frame_before(joint)
    @assert successor_pose.to == frame_after(joint)
    @assert predecessor ∈ bodies(mechanism)
    @assert joint ∉ joints(mechanism)

    # define where joint is attached on predecessor
    add_frame!(predecessor, joint_pose)

    # define where child is attached to joint
    add_frame!(successor, inv(successor_pose))

    if successor ∈ bodies(mechanism)
        add_edge!(mechanism.graph, predecessor, successor, joint)
    else
        add_edge!(mechanism.tree, predecessor, successor, joint)
        canonicalize_frame_definitions!(mechanism, successor)
    end
    register_modification!(mechanism)
    mechanism
end

Base.@deprecate(
        attach!(mechanism::Mechanism{T}, predecessor::RigidBody{T}, joint::GenericJoint{T},
            joint_to_predecessor::Transform3D, successor::RigidBody{T},
            successor_to_joint::Transform3D = eye(Transform3D{T}, default_frame(successor), frame_after(joint))) where {T},
        attach!(mechanism, predecessor, successor, joint;
            joint_pose = joint_to_predecessor, successor_pose = successor_to_joint))

function _copyjoint!(dest::Mechanism{T}, src::Mechanism{T}, srcjoint::GenericJoint{T},
        bodymap::Dict{RigidBody{T}, RigidBody{T}}, jointmap::Dict{GenericJoint{T}, GenericJoint{T}}) where {T}
    srcpredecessor = source(srcjoint, src.graph)
    srcsuccessor = target(srcjoint, src.graph)

    joint_to_predecessor = fixed_transform(srcpredecessor, frame_before(srcjoint), default_frame(srcpredecessor))
    successor_to_joint = fixed_transform(srcsuccessor, default_frame(srcsuccessor), frame_after(srcjoint))

    destpredecessor = get!(() -> deepcopy(srcpredecessor), bodymap, srcpredecessor)
    destsuccessor = get!(() -> deepcopy(srcsuccessor), bodymap, srcsuccessor)
    destjoint = jointmap[srcjoint] = deepcopy(srcjoint)

    attach!(dest, destpredecessor, destsuccessor, destjoint; joint_pose = joint_to_predecessor, successor_pose = successor_to_joint)
end

# TODO: use $(SIGNATURES) again once it isn't broken anymore
"""
attach!(mechanism, parentbody, childmechanism; child_root_pose)

Attach a copy of `childmechanism` to `mechanism`. Return mappings from the bodies and joints
of the `childmechanism` to the bodies and joints that were added to `mechanism`.

Essentially replaces the root body of a copy of `childmechanism` with `parentbody` (which
belongs to `mechanism`).

Note: gravitational acceleration for childmechanism is ignored.
"""
function attach!(mechanism::Mechanism{T}, parentbody::RigidBody{T}, childmechanism::Mechanism{T};
        child_root_pose = eye(Transform3D{T}, default_frame(root_body(childmechanism)), default_frame(parentbody))) where {T}
    # FIXME: test with cycles

    @assert mechanism != childmechanism # infinite loop otherwise

    bodymap = Dict{RigidBody{T}, RigidBody{T}}()
    jointmap = Dict{GenericJoint{T}, GenericJoint{T}}()

    # Define where child root body is located w.r.t parent body and add frames that were attached to childroot to parentbody.
    childroot = root_body(childmechanism)
    add_frame!(parentbody, child_root_pose)
    for transform in frame_definitions(childroot)
        add_frame!(parentbody, transform)
    end
    canonicalize_frame_definitions!(mechanism, parentbody)
    bodymap[childroot] = parentbody

    # Insert childmechanism's non-root vertices and joints, starting with the tree joints (to preserve order).
    for joint in flatten((tree_joints(childmechanism), non_tree_joints(childmechanism)))
        _copyjoint!(mechanism, childmechanism, joint, bodymap, jointmap)
    end
    bodymap, jointmap
end

"""
$(SIGNATURES)

Create a new `Mechanism` from the subtree of `mechanism` rooted at `submechanismroot`.

Also return mappings from the bodies and joints of the input mechanism to the
bodies and joints of the submechanism.

Any non-tree joint in `mechanism` will appear in the returned `Mechanism` if and
only if both its successor and its predecessor are part of the subtree.
"""
function submechanism(mechanism::Mechanism{T}, submechanismroot::RigidBody{T}) where {T}
    # FIXME: test with cycles

    bodymap = Dict{RigidBody{T}, RigidBody{T}}()
    jointmap = Dict{GenericJoint{T}, GenericJoint{T}}()

    # Create Mechanism
    root = bodymap[submechanismroot] = deepcopy(submechanismroot)
    ret = Mechanism(root; gravity = mechanism.gravitational_acceleration.v)

    # Add tree joints, preserving order in input mechanism.
    for joint in tree_joints(mechanism) # assumes toposort
        if haskey(bodymap, predecessor(joint, mechanism))
            _copyjoint!(ret, mechanism, joint, bodymap, jointmap)
        end
    end

    # Add non-tree joints.
    for joint in non_tree_joints(mechanism)
        if haskey(bodymap, predecessor(joint, mechanism)) && haskey(bodymap, successor(joint, mechanism))
            _copyjoint!(ret, mechanism, joint, bodymap, jointmap)
        end
    end

    ret, bodymap, jointmap
end

# TODO: use $(SIGNATURES) again once it isn't broken anymore
"""
rebuild_spanning_tree!(mechanism; flipped_joint_map, next_edge)

Reconstruct the mechanism's spanning tree.

Optionally, the `flipped_joint_map` keyword argument can be used to pass in an associative container
that will be populated with a mapping from original joints to flipped joints, if the rebuilding process
required the polarity of some joints to be flipped.

Also optionally, `next_edge` can be used to select which joints should become part of the
new spanning tree.
"""
function rebuild_spanning_tree!(mechanism::Mechanism{M},
        flipped_joint_map::Associative = Dict{GenericJoint{M}, GenericJoint{M}}();
        next_edge = first #= breadth first =#) where {M}
    mechanism.tree = SpanningTree(mechanism.graph, root_body(mechanism), flipped_joint_map; next_edge = next_edge)
    register_modification!(mechanism)
    canonicalize_frame_definitions!(mechanism)
end

# TODO: use $(SIGNATURES) again once it isn't broken anymore
"""
remove_joint!(mechanism, joint; flipped_joint_map, spanning_tree_next_edge)

Remove a joint from the mechanism. Rebuilds the spanning tree if the joint is
part of the current spanning tree.

Optionally, the `flipped_joint_map` keyword argument can be used to pass in an associative container
that will be populated with a mapping from original joints to flipped joints, if removing `joint`
requires rebuilding the spanning tree of `mechanism` and the polarity of some joints needed to be changed in the process.

Also optionally, `spanning_tree_next_edge` can be used to select which joints should become part of the
new spanning tree, if rebuilding the spanning tree is required.
"""
function remove_joint!(mechanism::Mechanism{M}, joint::GenericJoint{M};
        flipped_joint_map::Associative = Dict{GenericJoint{M}, GenericJoint{M}}(),
        spanning_tree_next_edge = first #= breadth first =#) where {M}
    istreejoint = joint ∈ tree_joints(mechanism)
    remove_edge!(mechanism.graph, joint)
    register_modification!(mechanism)
    istreejoint && rebuild_spanning_tree!(mechanism, flipped_joint_map; next_edge = spanning_tree_next_edge)
end

function replace_joint!(mechanism::Mechanism, oldjoint::Joint, newjoint::Joint)
    @assert frame_before(newjoint) == frame_before(oldjoint)
    @assert frame_after(newjoint) == frame_after(oldjoint)
    if oldjoint ∈ tree_joints(mechanism)
        replace_edge!(mechanism.tree, oldjoint, newjoint)
    else
        replace_edge!(mechanism.graph, oldjoint, newjoint)
    end
    register_modification!(mechanism)
    nothing
end

"""
$(SIGNATURES)

Remove any fixed joints present as tree edges in `mechanism` by merging the
rigid bodies that these fixed joints join together into bodies with equivalent
inertial properties. Return the fixed joints that were removed.
"""
function remove_fixed_tree_joints!(mechanism::Mechanism)
    # FIXME: test with cycles
    T = eltype(mechanism)
    graph = mechanism.graph

    # Update graph.
    fixedjoints = filter(j -> joint_type(j) isa Fixed, tree_joints(mechanism))
    newtreejoints = setdiff(tree_joints(mechanism), fixedjoints)
    for fixedjoint in fixedjoints
        pred = source(fixedjoint, graph)
        succ = target(fixedjoint, graph)

        # Add identity joint transform as a body-fixed frame definition.
        jointtransform = eye(Transform3D{T}, frame_after(fixedjoint), frame_before(fixedjoint))
        add_frame!(pred, jointtransform)

        # Migrate body fixed frames to parent body.
        for tf in frame_definitions(succ)
            add_frame!(pred, tf)
        end

        # Add inertia to parent body.
        if has_defined_inertia(pred)
            inertia = spatial_inertia(succ)
            parentinertia = spatial_inertia(pred)
            toparent = fixed_transform(pred, inertia.frame, parentinertia.frame)
            spatial_inertia!(pred, parentinertia + transform(inertia, toparent))
        end

        # Merge vertex into parent.
        for joint in copy(in_edges(succ, graph))
            if joint == fixedjoint
                remove_edge!(graph, joint)
            else
                rewire!(graph, joint, source(joint, graph), pred)
            end
        end
        for joint in copy(out_edges(succ, graph))
            rewire!(graph, joint, pred, target(joint, graph))
        end
        remove_vertex!(mechanism.graph, succ)
    end

    # Recompute spanning tree (preserves order for non-fixed joints)
    mechanism.tree = SpanningTree(graph, root_body(mechanism), newtreejoints)

    # Recanonicalize frames
    canonicalize_frame_definitions!(mechanism)

    register_modification!(mechanism)

    fixedjoints
end

# TODO: remove floating_non_tree_joints

"""
$(SIGNATURES)

Return a dynamically equivalent `Mechanism`, but with a flat tree structure
with all bodies attached to the root body with a quaternion floating joint, and
with the 'tree edge' joints of the input `Mechanism` transformed into non-tree
edge joints (a constraint enforced using Lagrange multipliers in `dynamics!`).
In addition, return:
* a mapping from bodies in the maximal-coordinate `Mechanism` to their floating joints.
* a mapping from bodies in the input `Mechanism` to bodies in the returned `Mechanism`
* a mapping from joints in the input `Mechanism` to joints in the returned `Mechanism`
"""
function maximal_coordinates(mechanism::Mechanism)
    T = eltype(mechanism)

    # Body and joint mapping.
    bodymap = Dict{RigidBody{T}, RigidBody{T}}()
    jointmap = Dict{GenericJoint{T}, GenericJoint{T}}()

    # Copy root.
    root = bodymap[root_body(mechanism)] = deepcopy(root_body(mechanism))
    ret = Mechanism(root, gravity = mechanism.gravitational_acceleration.v)

    # Copy non-root bodies and attach them to the root with a floating joint.
    newfloatingjoints = Dict{RigidBody{T}, GenericJoint{T}}()
    for srcbody in non_root_bodies(mechanism)
        framebefore = default_frame(root)
        frameafter = default_frame(srcbody)
        body = bodymap[srcbody] = deepcopy(srcbody)
        floatingjoint = newfloatingjoints[body] = Joint(string(body), framebefore, frameafter, QuaternionFloating{T}())
        attach!(ret, root, body, floatingjoint, joint_pose = eye(Transform3D{T}, framebefore), successor_pose = eye(Transform3D{T}, frameafter))
    end

    # Copy input Mechanism's joints.
    for joint in flatten((tree_joints(mechanism), non_tree_joints(mechanism)))
        _copyjoint!(ret, mechanism, joint, bodymap, jointmap)
    end

    ret, newfloatingjoints, bodymap, jointmap
end

function canonicalize_graph!(mechanism::Mechanism)
    root = root_body(mechanism)
    treejoints = copy(tree_joints(mechanism))
    vertices = append!([root], successor(joint, mechanism) for joint in treejoints)
    edges = vcat(treejoints, non_tree_joints(mechanism))
    reindex!(mechanism.graph, vertices, edges)
    mechanism.tree = SpanningTree(mechanism.graph, root, treejoints)
end

add_environment_primitive!(mechanism::Mechanism, halfspace::HalfSpace3D) = push!(mechanism.environment, halfspace)
"""
$(SIGNATURES)

Create a random tree `Mechanism` with the given joint types. Each new body is
attached to a parent selected using the `parentselector` function.
"""
function rand_tree_mechanism(::Type{T}, parentselector::Function, jointtypes::Vararg{Type{<:JointType{T}}}) where {T}
    parentbody = RigidBody{T}("world")
    mechanism = Mechanism(parentbody)
    for (i, jointtype) in enumerate(jointtypes)
        joint = Joint("joint$i", rand(jointtype))
        joint_to_parent_body = rand(Transform3D{T}, frame_before(joint), default_frame(parentbody))
        body = RigidBody(rand(SpatialInertia{T}, CartesianFrame3D("body$i")))
        body_to_joint = eye(Transform3D{T}, default_frame(body), frame_after(joint))
        attach!(mechanism, parentbody, body, joint, joint_pose = joint_to_parent_body, successor_pose = body_to_joint)
        parentbody = parentselector(mechanism)
    end
    return mechanism
end
rand_tree_mechanism(parentselector::Function, jointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_tree_mechanism(T, parentselector, jointtypes...)

"""
$(SIGNATURES)

Create a random chain `Mechanism` with the given joint types.
"""
rand_chain_mechanism(::Type{T}, jointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_tree_mechanism(T, mechanism::Mechanism -> last(bodies(mechanism)), jointtypes...)
rand_chain_mechanism(jointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_chain_mechanism(T, jointtypes...)

"""
$(SIGNATURES)

Create a random tree `Mechanism`.
"""
rand_tree_mechanism(::Type{T}, jointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_tree_mechanism(T, mechanism::Mechanism -> rand(bodies(mechanism)), jointtypes...)
rand_tree_mechanism(jointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_tree_mechanism(T, jointtypes...)

"""
$(SIGNATURES)

Create a random tree `Mechanism`, with a quaternion floating
joint as the first joint (between the root body and the first non-root body).
"""
function rand_floating_tree_mechanism(::Type{T}, nonfloatingjointtypes::Vararg{Type{<:JointType{T}}}) where {T}
    parentselector = (mechanism::Mechanism) -> begin
        only_root = length(bodies(mechanism)) == 1
        only_root ? root_body(mechanism) : rand(collect(non_root_bodies(mechanism)))
    end
    rand_tree_mechanism(parentselector, QuaternionFloating{T}, nonfloatingjointtypes...)
end
rand_floating_tree_mechanism(nonfloatingjointtypes::Vararg{Type{<:JointType{T}}}) where {T} = rand_floating_tree_mechanism(T, nonfloatingjointtypes...)
