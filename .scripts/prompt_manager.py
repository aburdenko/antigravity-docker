import os
from pathlib import Path
from typing import Dict, Any, Optional, Union

class PromptManager:
    """
    Manages loading and formatting of prompts from template files.
    """
    def __init__(self, template_dir: str):
        """
        Initializes the PromptManager.

        Args:
            template_dir: The path to the directory containing prompt templates.
        """
        self.template_dir = Path(template_dir)
        if not self.template_dir.is_dir():
            raise ValueError(f"Template directory not found: {self.template_dir}")

    def _read_file(self, file_path: Union[str, Path]) -> str:
        """Reads a file from the given path."""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                return f.read()
        except FileNotFoundError:
            raise FileNotFoundError(f"Template file not found: {file_path}")

    def generate_prompt(self, template_name: str, data: Optional[Dict[str, Any]] = None) -> str:
        """
        Loads a prompt template, optionally fills it with data, and returns the final prompt.

        Args:
            template_name: The name of the template file relative to the template_dir.
                           e.g., "system_prompt.md" or "use_case_1_exclusions/user_prompt_template.md"
            data: A dictionary of data to format the template with. If None, no formatting is done.

        Returns:
            The final, formatted prompt as a string.
        """
        file_path = self.template_dir / template_name
        template_content = self._read_file(file_path)

        if data:
            return template_content.format(**data)

        # If no data, return content as is. This is useful for static prompts.
        return template_content

    def create_prompt_from_use_case(self, use_case_config_path: str, dynamic_data: Optional[Dict[str, Any]] = None) -> str:
        """
        Loads a use case config, finds the template, fills it with variables,
        and returns the final prompt.

        Args:
            use_case_config_path: The path to the use case YAML config file,
                                  relative to the template_dir.
                                  e.g., "use_cases/exclusions_340b_rebate.yaml"
            dynamic_data: A dictionary of data to merge with the variables from
                          the config file. This is useful for data that is only
                          available at runtime, like contract chunks.
                          This data will overwrite config variables if keys conflict.

        Returns:
            The final, formatted prompt as a string.
        """
        try:
            import yaml
        except ImportError:
            raise ImportError("PyYAML is required for this feature. Please install it using 'pip install PyYAML'.")

        full_config_path = self.template_dir / use_case_config_path
        config_content = self._read_file(full_config_path)
        config = yaml.safe_load(config_content) or {} # Handle empty YAML files

        template_name = config.get("template")
        if not template_name:
            # Convention: if 'template' key is missing, derive template name
            # by removing the .yaml/.yml extension from the config file path.
            # e.g., 'prompts/my_template.md.yaml' -> 'prompts/my_template.md'
            template_name, ext = os.path.splitext(use_case_config_path)
            if ext.lower() not in ['.yaml', '.yml']:
                raise ValueError(f"Config file '{use_case_config_path}' is not a .yaml or .yml file, and is missing the 'template' key.")

            # Verify the conventionally-derived template file exists
            if not (self.template_dir / template_name).is_file():
                raise FileNotFoundError(
                    f"Config file '{use_case_config_path}' is missing the 'template' key, "
                    f"and the conventionally-derived template file '{template_name}' was not found in '{self.template_dir}'."
                )

        # The 'variables' key is optional in the YAML file. Handle None if key exists but is null.
        variables = config.get("variables", {}) or {}
        if dynamic_data:
            variables.update(dynamic_data)

        # Automatically stringify complex variables (lists/dicts) to be injected
        # into the prompt template as a JSON string. This allows using native
        # YAML structures in the config files for better readability.
        import json
        for key, value in variables.items():
            if isinstance(value, (dict, list)):
                variables[key] = json.dumps(value, indent=2)

        return self.generate_prompt(template_name, variables)

    def generate_prompt_from_template_with_companion_yaml(self, template_name: str, dynamic_data: Optional[Dict[str, Any]] = None) -> str:
        """
        Generates a prompt from a template file. It checks for a companion YAML
        file by convention (e.g., 'template.md' -> 'template.md.yaml') and uses
        it for variables if it exists.

        Args:
            template_name: The name of the template file relative to the template_dir.
            dynamic_data: A dictionary of data to merge with variables from the
                          companion YAML file. This data will overwrite YAML
                          variables if keys conflict.

        Returns:
            The final, formatted prompt as a string. If no companion YAML is
            found, the template is formatted only with dynamic_data (if provided).
        """
        template_full_path = self.template_dir / template_name
        template_content = self._read_file(template_full_path)

        companion_yaml_path = template_full_path.with_suffix(template_full_path.suffix + '.yaml')

        variables = {}
        if companion_yaml_path.is_file():
            try:
                import yaml
            except ImportError:
                raise ImportError("PyYAML is required for this feature. Please install it using 'pip install PyYAML'.")

            yaml_content = self._read_file(companion_yaml_path)
            yaml_vars = yaml.safe_load(yaml_content) or {}
            variables.update(yaml_vars)

        if dynamic_data:
            variables.update(dynamic_data)

        if not variables:
            return template_content

        # Automatically stringify complex variables
        import json
        for key, value in variables.items():
            if isinstance(value, (dict, list)):
                variables[key] = json.dumps(value, indent=2)

        return template_content.format(**variables)