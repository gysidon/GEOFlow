#!/usr/bin/env python3
"""
模拟 Docker Compose 的多文件合并语义，校验 docker-compose.external-db.yml 的覆盖效果。

实现依据（Docker 官方 Compose 合并规范）：
  - Mapping：按键合并，冲突时后者覆盖前者，其余键保留
  - Sequence：直接拼接（ports / volumes / dns / env_file / networks）
  - 特殊键 command / entrypoint / healthcheck.test：整体替换
  - !reset <value>：把目标属性重置为该类型的默认值或 null
  - !override <value>：完全替换目标属性，绕过标准合并规则
  - depends_on 使用长语法（Mapping）时按键合并

用法：
    python3 tools/verify-external-db-override.py
"""

import sys
import yaml

RESET = "!reset"
OVERRIDE = "!override"


class ComposeLoader(yaml.SafeLoader):
    """识别 !reset / !override 自定义标签。"""


def _reset_constructor(loader, node):
    # 标签值被忽略，目标属性置为默认类型值或 null
    if isinstance(node, yaml.MappingNode):
        return {}
    if isinstance(node, yaml.SequenceNode):
        return []
    return None


def _override_constructor(loader, node):
    # 保留原值，但打上标记以便合并时整体替换
    if isinstance(node, yaml.MappingNode):
        return {"__override__": True, "value": loader.construct_mapping(node, deep=True)}
    if isinstance(node, yaml.SequenceNode):
        return {"__override__": True, "value": loader.construct_sequence(node, deep=True)}
    return {"__override__": True, "value": loader.construct_scalar(node)}


ComposeLoader.add_constructor(RESET, _reset_constructor)
ComposeLoader.add_constructor(OVERRIDE, _override_constructor)

REPLACE_WHOLE = {"command", "entrypoint", "healthcheck"}


def is_override(value):
    return isinstance(value, dict) and value.get("__override__") is True


def merge_mapping(base, override):
    result = dict(base)
    for key, val in override.items():
        if is_override(val):
            result[key] = val["value"]
        elif key in result and isinstance(result[key], dict) and isinstance(val, dict):
            result[key] = merge_mapping(result[key], val)
        else:
            result[key] = val
    return result


def merge_services(base, override):
    result = dict(base)
    for name, svc in override.items():
        if svc is None:  # !reset null
            result.pop(name, None)
            continue
        if name not in result:
            result[name] = svc
            continue
        merged = dict(result[name])
        for key, val in svc.items():
            if is_override(val):
                merged[key] = val["value"]
            elif key in REPLACE_WHOLE:
                merged[key] = val
            elif key in merged and isinstance(merged[key], dict) and isinstance(val, dict):
                merged[key] = merge_mapping(merged[key], val)
            elif key in merged and isinstance(merged[key], list) and isinstance(val, list):
                merged[key] = merged[key] + val
            else:
                merged[key] = val
        result[name] = merged
    return result


def main():
    import os

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base_path = os.path.join(root, "docker-compose.prod.yml")
    override_path = os.path.join(root, "docker-compose.external-db.yml")
    prebuilt_path = os.path.join(root, "docker-compose.prebuilt.yml")

    with open(base_path, encoding="utf-8") as fh:
        base = yaml.load(fh, Loader=ComposeLoader)
    with open(override_path, encoding="utf-8") as fh:
        override = yaml.load(fh, Loader=ComposeLoader)

    merged = merge_services(base.get("services", {}), override.get("services", {}))

    errors = []
    ok = []

    # 1. postgres / redis 必须已移除
    for svc in ("postgres", "redis"):
        if svc in merged:
            errors.append(f"服务 {svc} 未被移除")
        else:
            ok.append(f"服务 {svc} 已移除")

    # 2. 任何服务都不得再依赖 postgres / redis
    for name, svc in merged.items():
        deps = svc.get("depends_on") or {}
        dep_names = list(deps.keys()) if isinstance(deps, dict) else list(deps)
        for dep in dep_names:
            if dep in ("postgres", "redis"):
                errors.append(f"服务 {name} 仍依赖 {dep}")
        for dep in dep_names:
            if dep not in merged:
                errors.append(f"服务 {name} 依赖不存在的服务 {dep}")

    if not any("仍依赖" in e for e in errors):
        ok.append("无残留的 postgres / redis 依赖引用")

    # 3. 应用侧服务必须保留 init 依赖（保证迁移先于常驻服务）
    expect_init = [
        "app",
        "web",
        "queue",
        "ai-quality-queue",
        "ai-quality-backfill-queue",
        "ai-optimization-queue",
        "knowledge-queue",
        "scheduler",
        "reverb",
    ]
    for name in expect_init:
        svc = merged.get(name)
        if svc is None:
            errors.append(f"服务 {name} 丢失")
            continue
        deps = svc.get("depends_on") or {}
        dep_names = list(deps.keys()) if isinstance(deps, dict) else list(deps)
        if name == "web":
            # web 依赖 app 与 reverb，不依赖 init
            if "init" in dep_names:
                errors.append("web 不应直接依赖 init")
            continue
        if "init" not in dep_names:
            errors.append(f"服务 {name} 丢失了 init 依赖")
    if not any("丢失了 init" in e for e in errors):
        ok.append("全部常驻服务保留 init 依赖顺序")

    # 4. init 必须不再有任何 depends_on
    init_deps = merged.get("init", {}).get("depends_on") or {}
    init_dep_names = list(init_deps.keys()) if isinstance(init_deps, dict) else list(init_deps)
    if init_dep_names:
        errors.append(f"init 仍声明依赖 {init_dep_names}")
    else:
        ok.append("init 已清空 depends_on")

    # 5. 需要访问外部实例的服务必须有 host.docker.internal 映射
    need_hosts = [
        "init",
        "app",
        "queue",
        "ai-quality-queue",
        "ai-quality-backfill-queue",
        "ai-optimization-queue",
        "knowledge-queue",
        "scheduler",
        "reverb",
    ]
    for name in need_hosts:
        svc = merged.get(name)
        if svc is None:
            continue
        hosts = svc.get("extra_hosts") or []
        if not any("host.docker.internal" in str(h) for h in hosts):
            errors.append(f"服务 {name} 缺少 host.docker.internal 映射")
    if not any("缺少 host.docker" in e for e in errors):
        ok.append("全部应用侧服务含 host.docker.internal 映射")

    # 6. 镜像构建配置未被破坏
    app = merged.get("app", {})
    if "build" not in app:
        errors.append("app 服务丢失 build 段")
    else:
        ok.append("app 保留 build 段")
    if not app.get("image"):
        errors.append("app 服务丢失 image")
    else:
        ok.append("app 保留 image")

    # 7. 同一份 override 也必须能叠加到 prebuilt 编排上
    with open(prebuilt_path, encoding="utf-8") as fh:
        prebuilt = yaml.load(fh, Loader=ComposeLoader)
    merged_pre = merge_services(prebuilt.get("services", {}), override.get("services", {}))
    for svc in ("postgres", "redis"):
        if svc in merged_pre:
            errors.append(f"prebuilt 叠加后 {svc} 未被移除")
    for name, svc in merged_pre.items():
        deps = svc.get("depends_on") or {}
        dep_names = list(deps.keys()) if isinstance(deps, dict) else list(deps)
        for dep in dep_names:
            if dep in ("postgres", "redis"):
                errors.append(f"prebuilt 叠加后服务 {name} 仍依赖 {dep}")
    if not any("prebuilt" in e for e in errors):
        ok.append("override 同时兼容 prebuilt 编排")

    print("=" * 62)
    print("docker-compose.external-db.yml 合并校验")
    print("=" * 62)
    for line in ok:
        print(f"  [OK]   {line}")
    for line in errors:
        print(f"  [FAIL] {line}")
    print("=" * 62)
    if errors:
        print(f"结果：{len(errors)} 项失败")
        return 1
    print(f"结果：全部 {len(ok)} 项通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
