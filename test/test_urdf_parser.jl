@testset "URDF parser" begin
    @testset "joint bounds" begin
        acrobot = parse_urdf(Float64, joinpath(@__DIR__, "urdf", "Acrobot.urdf"))
        @test position_bounds(findjoint(acrobot, "shoulder")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]
        @test velocity_bounds(findjoint(acrobot, "shoulder")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]
        @test effort_bounds(findjoint(acrobot, "shoulder")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]
        @test position_bounds(findjoint(acrobot, "elbow")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]
        @test velocity_bounds(findjoint(acrobot, "elbow")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]
        @test effort_bounds(findjoint(acrobot, "elbow")) == [RigidBodyDynamics.Bounds(-Inf, Inf)]

        acrobot_with_limits = parse_urdf(Float64, joinpath(@__DIR__, "urdf", "Acrobot_with_limits.urdf"))
        @test position_bounds(findjoint(acrobot_with_limits, "shoulder")) == [RigidBodyDynamics.Bounds(-6.28, 6.28)]
        @test velocity_bounds(findjoint(acrobot_with_limits, "shoulder")) == [RigidBodyDynamics.Bounds(-10, 10)]
        @test effort_bounds(findjoint(acrobot_with_limits, "shoulder")) == [RigidBodyDynamics.Bounds(0, 0)]
        @test position_bounds(findjoint(acrobot_with_limits, "elbow")) == [RigidBodyDynamics.Bounds(-6.28, 6.28)]
        @test velocity_bounds(findjoint(acrobot_with_limits, "elbow")) == [RigidBodyDynamics.Bounds(-10, 10)]
        @test effort_bounds(findjoint(acrobot_with_limits, "elbow")) == [RigidBodyDynamics.Bounds(-5, 5)]
    end
end

