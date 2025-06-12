#!/bin/bash
# 阿里云安全组IP白名单自动更新脚本
# 功能：使用阿里云cli自动更新阿里云安全组规则中的源IP地址为当前公网IP，并更新RDS白名单模板中的IP地址为当前公网IP
# 前提：1. 需要在"RAM访问控制"添加"权限策略" https://ram.console.aliyun.com/policies 创建权限策略 -> 脚本编辑 -> 保存
#      2. 创建用户并添加刚创建的权限策略，以获取AccessKey ID和AccessKey Secret
# {
#   "Version": "1",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Action": "ecs:ModifySecurityGroupRule",
#       "Resource": "*"
#     },
#     {
#       "Effect": "Allow",
#       "Action": "ecs:DescribeSecurityGroupAttribute",
#       "Resource": "*"
#     },
#     {
#       "Effect": "Allow",
#       "Action": "rds:DescribeAllWhitelistTemplate",
#       "Resource": "*"
#     },
#     {
#       "Effect": "Allow",
#       "Action": "rds:ModifyWhitelistTemplate",
#       "Resource": "*"
#     },
#     {
#       "Effect": "Allow",
#       "Action": "rds:DescribeWhitelistTemplate",
#       "Resource": "*"
#     }
#   ]
# }

# 阿里云配置，根据实际情况修改
REGION="cn-huhehaote" # 区域
SECURITY_GROUP_ID="sg-hp3io8dryrkwsrg4jdex" # 安全组ID
# 格式：规则描述:优先级 
SERVICES=(
  "SSH:100"
  "Redis:100"
)
# RDS白名单模板配置
RDS_TEMPLATE_ID=27 # RDS白名单模板ID（https://api.aliyun.com/document/Rds/2014-08-15/DescribeAllWhitelistTemplate）

# 下面默认配置无需修改
PROFILE_NAME="AkProfile" # 配置文件名
CONFIG_FILE="$HOME/.aliyun/config.json" # 配置文件路径

# 初始化全局变量
NEW_IP=""
RULES_JSON=""
SERVICE_NAMES=()
SERVICE_RULE_IDS=()
SERVICE_CURRENT_IPS=()
SERVICE_PRIORITIES=()

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
  echo "${GREEN}[信息]${NC} $1"
}

log_warn() {
  echo "${YELLOW}[警告]${NC} $1"
}

log_error() {
  echo "${RED}[错误]${NC} $1"
}

# 显示帮助信息
show_help() {
  echo "${BLUE}阿里云安全组IP白名单自动更新脚本${NC}"
  echo "用法: $0 [选项]"
  echo "选项:"
  echo "  -h, --help     显示此帮助信息"
  echo "  -y, --yes      自动确认所有操作，不提示"
  echo "  -d, --dry-run  仅显示将要执行的操作，不实际执行"
  echo "  -f, --force    强制执行，忽略代理检测警告"
}

# 检测代理设置
check_proxy() {
  if [ "$FORCE_EXEC" = true ]; then
    log_warn "强制执行模式，跳过代理检测"
    return 0
  fi
  
  local proxy_detected=false
  local proxy_vars=("http_proxy" "https_proxy" "ALL_PROXY" "HTTP_PROXY" "HTTPS_PROXY" "all_proxy")
  local detected_proxies=()
  
  for var in "${proxy_vars[@]}"; do
    if [ -n "${!var}" ]; then
      proxy_detected=true
      detected_proxies+=("$var=${!var}")
    fi
  done
  
  if [ "$proxy_detected" = true ]; then
    log_error "检测到代理设置，这可能导致获取的公网IP不准确！"
    echo "检测到以下代理环境变量:"
    for proxy in "${detected_proxies[@]}"; do
      echo "  - $proxy"
    done
    echo ""
    log_warn "使用代理获取的IP可能是代理服务器的IP，而非您的真实公网IP"
    log_warn "建议临时关闭代理后再运行此脚本"
    
    if [ "$AUTO_CONFIRM" = false ]; then
      read -p "是否仍然继续执行？(y/n): " continue_with_proxy
      if [[ $continue_with_proxy != [yY] ]]; then
        log_info "操作已取消，请关闭代理后再试"
        exit 0
      fi
    else
      log_warn "自动确认模式下继续执行，但可能导致错误的IP被设置到安全组规则"
    fi
    
    echo ""
  fi
}

# 检查配置文件和凭证
check_and_setup_credentials() {
  local need_setup=false
  local ak_id=""
  local ak_secret=""
  
  # 检查配置文件是否存在
  if [ ! -f "$CONFIG_FILE" ]; then
    log_warn "阿里云CLI配置文件不存在: $CONFIG_FILE"
    need_setup=true
  else
    # 检查是否已配置AK/SK
    ak_id=$(aliyun configure get access-key-id --profile $PROFILE_NAME 2>/dev/null)
    if [ -z "$ak_id" ]; then
      log_warn "未找到AccessKey ID配置"
      need_setup=true
    else
      ak_secret=$(aliyun configure get access-key-secret --profile $PROFILE_NAME 2>/dev/null)
      if [ -z "$ak_secret" ]; then
        log_warn "未找到AccessKey Secret配置"
        need_setup=true
      fi
    fi
  fi
  
  # 如果需要设置凭证，则通过交互方式获取
  if [ "$need_setup" = true ]; then
    log_info "请输入阿里云访问凭证"
    read -p "AccessKey ID: " ak_id
    read -s -p "AccessKey Secret: " ak_secret
    echo ""
    
    if [ -z "$ak_id" ] || [ -z "$ak_secret" ]; then
      log_error "AccessKey ID和AccessKey Secret不能为空"
      exit 1
    fi
    
    # 配置阿里云CLI
    log_info "配置阿里云CLI..."
    aliyun configure set \
      --profile $PROFILE_NAME \
      --mode AK \
      --access-key-id "$ak_id" \
      --access-key-secret "$ak_secret" \
      --region $REGION
      
    if [ $? -ne 0 ]; then
      log_error "配置阿里云CLI失败"
      exit 1
    fi
    
    log_info "阿里云CLI配置完成"
  else
    log_info "使用已有的阿里云CLI配置"
  fi
}

# 显示当前CLI配置信息
display_current_config() {
  log_info "--------------------------------------------------"
  log_info "当前阿里云CLI配置信息:"
  if [ ! -f "$CONFIG_FILE" ]; then
    log_warn "未找到配置文件: $CONFIG_FILE"
    return
  fi
  
  log_info "配置文件位置: $CONFIG_FILE"
  log_info "当前使用的配置文件(profile): $PROFILE_NAME"
  
  # 提取并显示当前配置的关键信息
  local current_region=$(aliyun configure get region --profile $PROFILE_NAME)
  local current_mode=$(aliyun configure get mode --profile $PROFILE_NAME)
  local current_ak_id=$(aliyun configure get access-key-id --profile $PROFILE_NAME | sed 's/\(.\{4\}\).*\(.\{4\}\)/\1***\2/') # 仅显示前4位和后4位
  
  log_info "认证模式: $current_mode"
  log_info "区域: $current_region"
  log_info "AccessKey ID: $current_ak_id"
  log_info "--------------------------------------------------"
}

# 获取当前公网IP
get_public_ip() {
  log_info "获取当前公网IP..."
  # 使用多个IP检测服务以提高可靠性
  local ip_services=(
    "ipinfo.io/ip"
    "ifconfig.me"
    "api.ipify.org"
  )

  for service in "${ip_services[@]}"; do
    log_info "尝试从 $service 获取IP..."
    local temp_ip=$(curl -s $service)
    if [[ $temp_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEW_IP=$temp_ip
      log_info "成功获取IP: $NEW_IP (来源: $service)"
      return 0
    else
      log_warn "从 $service 获取IP失败，尝试下一个服务..."
    fi
  done

  log_error "无法获取当前公网IP，请检查网络连接"
  return 1
}

# 获取安全组规则
fetch_security_group_rules() {
  log_info "获取安全组规则信息..."
  RULES_JSON=$(aliyun ecs DescribeSecurityGroupAttribute \
    --SecurityGroupId $SECURITY_GROUP_ID \
    --RegionId $REGION \
    --NicType internet \
    --Direction ingress)

  if [ $? -ne 0 ]; then
    log_error "获取安全组规则失败"
    return 1
  fi
  
  return 0
}

# 解析安全组规则
parse_security_group_rules() {
  log_info "解析安全组规则..."
  local need_update=false
  local valid_rule_count=0

  # 清空之前的数组
  SERVICE_NAMES=()
  SERVICE_RULE_IDS=()
  SERVICE_CURRENT_IPS=()
  SERVICE_PRIORITIES=()

  # 遍历配置的服务，提取对应规则ID和当前IP
  for service_config in "${SERVICES[@]}"; do
    # 拆分服务配置为服务名和优先级
    local service_name=$(echo "$service_config" | cut -d':' -f1)
    local priority=$(echo "$service_config" | cut -d':' -f2)
    
    # 查找规则ID和当前IP
    local rule_id=$(echo "$RULES_JSON" | grep -A20 "\"Description\": \"$service_name\"" | grep -m1 '"SecurityGroupRuleId":' | awk -F'"' '{print $4}')
    local current_ip=$(echo "$RULES_JSON" | grep -A20 "\"Description\": \"$service_name\"" | grep -m1 '"SourceCidrIp":' | awk -F'"' '{print $4}')
    
    if [ -z "$rule_id" ]; then
      log_warn "未找到服务 '$service_name' 对应的安全组规则"
      continue
    fi
    
    # 存储规则信息到数组
    SERVICE_NAMES+=("$service_name")
    SERVICE_RULE_IDS+=("$rule_id")
    SERVICE_CURRENT_IPS+=("$current_ip")
    SERVICE_PRIORITIES+=("$priority")
    
    log_info "$service_name 规则: 当前IP: $current_ip"
    
    # 检查是否需要更新
    if [ "$current_ip" != "$NEW_IP" ]; then
      need_update=true
    fi
    
    ((valid_rule_count++))
  done

  # 如果没有找到任何规则，退出
  if [ $valid_rule_count -eq 0 ]; then
    log_error "未找到任何匹配的安全组规则，请检查服务配置"
    return 1
  fi

  # 如果所有规则的IP都与新IP相同，则不需要更新
  if [ "$need_update" = false ]; then
    log_info "所有规则的当前IP都与获取的公网IP相同，无需更新"
    return 2
  fi
  
  return 0
}

# 获取RDS白名单模板信息
fetch_rds_whitelist_template() {
  log_info "获取RDS白名单模板信息..."
  
  if [ -z "$RDS_TEMPLATE_ID" ]; then
    log_warn "未配置RDS白名单模板ID，跳过RDS白名单更新"
    return 2
  fi
  
  local template_json=$(aliyun rds DescribeWhitelistTemplate \
    --TemplateId $RDS_TEMPLATE_ID)
  
  if [ $? -ne 0 ]; then
    log_error "获取RDS白名单模板信息失败"
    return 1
  fi
  
  # 提取当前白名单IP
  local current_ips=$(echo "$template_json" | grep -m1 '"Ips":' | awk -F'"' '{print $4}')
  
  if [ -z "$current_ips" ]; then
    log_warn "未找到RDS白名单模板中的IP信息"
    return 1
  fi
  
  log_info "RDS白名单模板ID: $RDS_TEMPLATE_ID, 当前IP: $current_ips"
  
  # 检查是否需要更新
  if [ "$current_ips" == "$NEW_IP" ]; then
    log_info "RDS白名单模板中的IP与当前公网IP相同，无需更新"
    return 2
  fi
  
  RDS_CURRENT_IPS=$current_ips
  return 0
}

# 显示将要执行的更新
display_update_plan() {
  echo ""
  log_info "将执行以下操作:"
  local index=1
  
  # 显示安全组规则更新计划
  for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
    local service_name=${SERVICE_NAMES[$i]}
    local rule_id=${SERVICE_RULE_IDS[$i]}
    local current_ip=${SERVICE_CURRENT_IPS[$i]}
    
    # 只显示需要更新的规则
    if [ "$current_ip" != "$NEW_IP" ]; then
      echo "$index. 更新 $service_name 规则 ($rule_id) 的源IP: $current_ip -> $NEW_IP"
      ((index++))
    fi
  done
  
  # 显示RDS白名单更新计划
  if [ -n "$RDS_CURRENT_IPS" ] && [ "$RDS_CURRENT_IPS" != "$NEW_IP" ]; then
    echo "$index. 更新RDS白名单模板 ($RDS_TEMPLATE_ID) 的IP: $RDS_CURRENT_IPS -> $NEW_IP"
  fi
  
  echo ""
}

# 执行规则更新
update_security_group_rules() {
  # 更新规则
  for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
    local service_name=${SERVICE_NAMES[$i]}
    local rule_id=${SERVICE_RULE_IDS[$i]}
    local current_ip=${SERVICE_CURRENT_IPS[$i]}
    local priority=${SERVICE_PRIORITIES[$i]}
    
    # 只更新需要更新的规则
    if [ "$current_ip" != "$NEW_IP" ]; then
      log_info "更新 $service_name 规则..."
      local update_result=$(aliyun ecs ModifySecurityGroupRule \
        --RegionId $REGION \
        --SecurityGroupId $SECURITY_GROUP_ID \
        --SecurityGroupRuleId $rule_id \
        --SourceCidrIp $NEW_IP \
        --Priority $priority)
      
      if [ $? -ne 0 ]; then
        log_error "更新 $service_name 规则失败"
        echo "$update_result"
      else
        log_info "$service_name 规则更新成功"
      fi
    fi
  done
  
  log_info "安全组规则更新完成"
}

# 更新RDS白名单模板
update_rds_whitelist_template() {
  if [ -z "$RDS_TEMPLATE_ID" ] || [ -z "$RDS_CURRENT_IPS" ]; then
    return 0
  fi
  
  # 只有当当前IP与新IP不同时才更新
  if [ "$RDS_CURRENT_IPS" != "$NEW_IP" ]; then
    log_info "更新RDS白名单模板..."
    local update_result=$(aliyun rds ModifyWhitelistTemplate \
      --TemplateId $RDS_TEMPLATE_ID \
      --IpWhitelist $NEW_IP)
    
    if [ $? -ne 0 ]; then
      log_error "更新RDS白名单模板失败"
      echo "$update_result"
    else
      log_info "RDS白名单模板更新成功"
    fi
  fi
}

# 主函数
main() {
  # 参数解析
  AUTO_CONFIRM=false
  DRY_RUN=false
  FORCE_EXEC=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      -y|--yes)
        AUTO_CONFIRM=true
        shift
        ;;
      -d|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -f|--force)
        FORCE_EXEC=true
        shift
        ;;
      *)
        log_error "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done

  # 检测代理设置
  check_proxy
  
  # 检查和设置凭证
  check_and_setup_credentials
  
  # 显示当前配置
  display_current_config
  
  # 获取当前公网IP
  get_public_ip || exit 1
  
  # 获取安全组规则
  fetch_security_group_rules || exit 1
  
  # 解析安全组规则
  parse_security_group_rules
  local parse_result=$?
  local need_update_sg=true
  
  if [ $parse_result -eq 1 ]; then
    exit 1
  elif [ $parse_result -eq 2 ]; then
    need_update_sg=false
  fi
  
  # 获取RDS白名单模板信息
  RDS_CURRENT_IPS=""
  fetch_rds_whitelist_template
  local rds_result=$?
  local need_update_rds=true
  
  if [ $rds_result -eq 1 ]; then
    log_warn "RDS白名单模板处理失败，将跳过RDS白名单更新"
    need_update_rds=false
  elif [ $rds_result -eq 2 ]; then
    need_update_rds=false
  fi
  
  # 如果没有需要更新的内容，直接退出
  if [ "$need_update_sg" = false ] && [ "$need_update_rds" = false ]; then
    log_info "所有IP都已是最新，无需更新"
    exit 0
  fi
  
  # 显示更新计划
  display_update_plan
  
  # 如果是dry-run模式，到此结束
  if [ "$DRY_RUN" = true ]; then
    log_info "Dry-run模式，不执行实际操作"
    exit 0
  fi
  
  # 确认操作
  if [ "$AUTO_CONFIRM" = false ]; then
    read -p "是否继续执行? (y/n): " confirm
    if [[ $confirm != [yY] ]]; then
      log_info "操作已取消"
      exit 0
    fi
  fi
  
  # 执行更新
  if [ "$need_update_sg" = true ]; then
    update_security_group_rules
  fi
  
  if [ "$need_update_rds" = true ]; then
    update_rds_whitelist_template
  fi
  
  log_info "所有更新操作已完成"
}

# 执行主函数
main "$@"