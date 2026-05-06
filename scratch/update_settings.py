
import sys

def update_pbxproj(file_path):
    with open(file_path, 'r') as f:
        lines = f.readlines()

    recommended_settings = {
        'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER': 'YES',
        'CLANG_WARN_STRICT_PROTOTYPES': 'YES',
        'GCC_WARN_ID_AS_CONDITION': 'YES',
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
    }

    new_lines = []
    in_build_settings = False
    
    for i, line in enumerate(lines):
        new_lines.append(line)
        if 'buildSettings = {' in line:
            in_build_settings = True
            # We are inside a buildSettings block. 
            # We will add missing settings here.
            # We look ahead to see what's already there to avoid duplicates.
            j = i + 1
            existing_settings = {}
            while j < len(lines) and '};' not in lines[j]:
                if '=' in lines[j]:
                    key = lines[j].split('=')[0].strip()
                    existing_settings[key] = True
                j += 1
            
            for setting, value in recommended_settings.items():
                if setting not in existing_settings:
                    # Add the setting with proper indentation
                    indent = line.split('buildSettings')[0] + "\t\t\t\t"
                    new_lines.append(f"{indent}{setting} = {value};\n")
        elif '};' in line and in_build_settings:
            in_build_settings = False

    with open(file_path, 'w') as f:
        f.writelines(new_lines)

if __name__ == "__main__":
    update_pbxproj(sys.argv[1])
