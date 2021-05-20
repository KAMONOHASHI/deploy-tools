import yaml
import argparse

def extract_diff_prop(base_yaml, comp_yaml):
    """
    keep only toplevel props of base_yaml different from comp_yaml.
    """
    result = {}
    for key in base_yaml:
        if key not in comp_yaml:
            result[key] = base_yaml[key]
        elif base_yaml[key] == comp_yaml[key]:
            continue
        else:
            result[key] = base_yaml[key]
    return result

def load_arg():
    parser = argparse.ArgumentParser()
    parser.add_argument('base_yaml_path')
    parser.add_argument('comp_yaml_path')
    args = parser.parse_args()
    return args

def main():
    args = load_arg()
    result = {}
    with open(args.base_yaml_path, mode='r') as base_yaml_file:
        with open(args.comp_yaml_path, mode='r') as comp_yaml_file:
            base_yaml = yaml.safe_load(base_yaml_file)
            comp_yaml = yaml.safe_load(comp_yaml_file)
            result = extract_diff_prop(base_yaml or {}, comp_yaml or {})
    
    if result != {}:
        print(yaml.dump(result, default_flow_style=False))

if __name__ == '__main__':
    main()
