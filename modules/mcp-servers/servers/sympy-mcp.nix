{lib, ...}: {
  meta = {
    modes = {
      stdio = "sympy-mcp";
      http = "bridge";
    };
    scope = "remote";
    defaultPort = 19760;
    tools = ["calculate_curl" "calculate_divergence" "calculate_gradient" "calculate_tensor" "convert_to_units" "create_coordinate_system" "create_custom_metric" "create_matrix" "create_predefined_metric" "create_vector_field" "differentiate_expression" "dsolve_ode" "integrate_expression" "intro" "intro_many" "introduce_expression" "introduce_function" "matrix_determinant" "matrix_eigenvalues" "matrix_eigenvectors" "matrix_inverse" "pdsolve_pde" "print_latex_expression" "print_latex_tensor" "quantity_simplify_units" "reset_state" "search_predefined_metrics" "simplify_expression" "solve_algebraically" "solve_linear_system" "solve_nonlinear_system" "substitute_expression"];
  };

  settingsOptions = {};

  settingsToEnv = _cfg: _mode: {};
  settingsToArgs = _cfg: _mode: [];
}
