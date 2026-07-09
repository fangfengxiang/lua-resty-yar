#!/usr/bin/env bash
# 注释规范 + 语法规范检查脚本
# Convention check script: comment conventions + syntax conventions
# Usage: bash scripts/check_conventions.sh
# Exit code 0 = pass, non-zero = fail

set -euo pipefail

LIB_DIR="lib"
errors=0
warnings=0

# --- 辅助函数 ---

report_error() {
    local file="$1" line="$2" msg="$3"
    echo "ERROR: $file:$line: $msg"
    errors=$((errors + 1))
}

report_warning() {
    local file="$1" line="$2" msg="$3"
    echo "WARN:  $file:$line: $msg"
    warnings=$((warnings + 1))
}

# --- 检查 1: 禁止内联 setmetatable({}, {__index=Class}) 模式 ---
# Lua OOP 官方模式：Class.__index = Class + setmetatable(obj, Class)
# 禁止每次 new 创建新元表的写法（偏离标杆库 lua-resty-http/dkjson）
check_inline_setmetatable() {
    echo "=== Check 1: No inline setmetatable({}, {__index=...}) ==="
    while IFS= read -r match; do
        file=$(echo "$match" | cut -d: -f1)
        line=$(echo "$match" | cut -d: -f2)
        report_error "$file" "$line" \
            "inline setmetatable with __index creates new metatable per instance; use Class.__index = Class pattern instead"
    done < <(grep -rn 'setmetatable\s*(\s*{}\s*,\s*{\s*__index' "$LIB_DIR" 2>/dev/null || true)
}

# --- 检查 2: 工厂方法用点号 Class.new()，不用冒号 :new() ---
# 静态工厂方法用点号 . 调用（对标 lua-resty-http http.new()、lua-cjson cjson.new()）
check_factory_colon() {
    echo "=== Check 2: No :new() on static factory methods ==="
    # 匹配 Class:new( 模式 — 工厂方法不应使用冒号
    while IFS= read -r match; do
        file=$(echo "$match" | cut -d: -f1)
        line=$(echo "$match" | cut -d: -f2)
        report_error "$file" "$line" \
            "factory method should use dot notation Class.new(), not colon Class:new()"
    done < <(grep -rn '\.[A-Z][a-zA-Z]*:new\s*(' "$LIB_DIR" 2>/dev/null || true)
}

# --- 检查 3: 公开模块函数应有文档注释 ---
# 公开函数（_M.xxx = function）应该有 --- 或 -- 注释
check_missing_docs() {
    echo "=== Check 3: Public functions should have documentation ==="
    local lua_files
    lua_files=$(find "$LIB_DIR" -name '*.lua' 2>/dev/null || true)
    for file in $lua_files; do
        local line_num=0
        local prev_line=""
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            # 检测公开函数定义
            if echo "$line" | grep -qE '^\s*_M\.[a-z_]+\s*=\s*function'; then
                # 检查前一行是否有注释
                if ! echo "$prev_line" | grep -qE '^\s*---'; then
                    local func_name
                    func_name=$(echo "$line" | grep -oE '_M\.[a-z_]+' | head -1)
                    report_warning "$file" "$line_num" \
                        "$func_name has no doc comment (---) on preceding line"
                fi
            fi
            prev_line="$line"
        done < "$file"
    done
}

# --- 检查 4: error() level 使用字面量 2，不定义常量 ---
# error(msg, 2) 字面量，不定义 ERROR_LEVEL_CALLER = 2 之类的常量
check_error_level_constant() {
    echo "=== Check 4: error() level should be literal, no constant ==="
    while IFS= read -r match; do
        file=$(echo "$match" | cut -d: -f1)
        line=$(echo "$match" | cut -d: -f2)
        report_warning "$file" "$line" \
            "error() level should use literal (error(msg, 2)), not a constant variable"
    done < <(grep -rn 'error\s*(.*,\s*[A-Z_][A-Z_0-9]*\s*)' "$LIB_DIR" 2>/dev/null || true)
}

# --- 检查 5: 双语注释顺序——中文在前，英文在后 ---
# 当注释同时包含中文和英文时，中文块在前，英文块在后（保持 LSP 注解连续）
check_comment_order() {
    echo "=== Check 5: Bilingual comment order (Chinese before English) ==="
    local lua_files
    lua_files=$(find "$LIB_DIR" -name '*.lua' 2>/dev/null || true)
    for file in $lua_files; do
        local line_num=0
        local in_comment_block=false
        local block_start=0
        local saw_english_annotation=false
        local block_lines=""
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            # 检测 --- 注解行（EmmyLua/LSP）
            if echo "$line" | grep -qE '^\s*---'; then
                if [ "$in_comment_block" = false ]; then
                    in_comment_block=true
                    block_start=$line_num
                    block_lines=""
                    saw_english_annotation=false
                fi
                # 检测中文（CJK 统一表意文字区，兼容 macOS BSD grep + Ubuntu GNU grep）
                if echo "$line" | LC_ALL=en_US.UTF-8 grep -q '[一-鿿]'; then
                    if [ "$saw_english_annotation" = true ]; then
                        report_warning "$file" "$line_num" \
                            "Chinese comment after English annotation breaks English block continuity; put Chinese before English"
                    fi
                fi
                # 检测英文 LSP 注解参数（如 @param, @return）
                if echo "$line" | grep -qE '^\s*---\s*@(param|return|field|class|see|module)'; then
                    saw_english_annotation=true
                fi
                block_lines="$block_lines $line"
            else
                in_comment_block=false
            fi
        done < "$file"
    done
}

# --- 主流程 ---

echo "=== Convention Check: lib/ ==="
echo ""

check_inline_setmetatable
echo ""
check_factory_colon
echo ""
check_missing_docs
echo ""
check_error_level_constant
echo ""
check_comment_order

echo ""
echo "=== Summary ==="
echo "Errors:   $errors"
echo "Warnings: $warnings"

if [ "$errors" -gt 0 ]; then
    echo "RESULT: FAIL ($errors errors)"
    exit 1
fi

echo "RESULT: PASS (0 errors, $warnings warnings)"
exit 0
