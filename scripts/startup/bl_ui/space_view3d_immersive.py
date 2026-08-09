# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Immersive Space options in the View3D / Image Editor N-panel (sidebar)."""

import bpy
from bpy.types import Panel, PropertyGroup
from bpy.props import BoolProperty, FloatProperty, EnumProperty


def _has_immersive_ops():
    return hasattr(bpy.ops.wm, "ios_immersive_toggle")


def _update_hand_as_pen(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_hand_as_pen"):
        return
    bpy.ops.wm.ios_immersive_set_hand_as_pen(enable=self.use_hand_as_pen)


def _update_hand_proximity_sculpt(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_hand_proximity_sculpt"):
        return
    bpy.ops.wm.ios_immersive_set_hand_proximity_sculpt(enable=self.hand_proximity_sculpt)


def _update_strength(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_strength"):
        return
    bpy.ops.wm.ios_immersive_set_strength(strength=self.strength)


def _update_radius(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_radius"):
        return
    bpy.ops.wm.ios_immersive_set_radius(radius=self.radius)


def _update_dyntopo(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_dyntopo"):
        return
    bpy.ops.wm.ios_immersive_set_dyntopo(enable=self.use_dyntopo)


def _update_mode(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_mode"):
        return
    bpy.ops.wm.ios_immersive_set_mode(mode=int(self.mode))


def _update_usd_refresh_interval(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_usd_refresh_interval"):
        return
    bpy.ops.wm.ios_immersive_set_usd_refresh_interval(seconds=self.usd_refresh_interval)


def _update_sync_transforms(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_sync_transforms"):
        return
    bpy.ops.wm.ios_immersive_set_sync_transforms(enable=self.sync_transforms_to_space)


_MUSE_BRUSH_ITEMS = (
    ('0', "Draw", "Draw"),
    ('1', "Clay", "Clay"),
    ('2', "Grab", "Grab"),
    ('3', "Smooth", "Smooth"),
    ('4', "Inflate+", "インフレート加算"),
    ('5', "Inflate−", "デフレート"),
    ('6', "Mask", "スカルプトマスク"),
)


def _update_muse_knock_single(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_muse_knock_brush"):
        return
    bpy.ops.wm.ios_immersive_set_muse_knock_brush(knock=1, kind=int(self.muse_knock_single))


def _update_muse_knock_double(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_muse_knock_brush"):
        return
    bpy.ops.wm.ios_immersive_set_muse_knock_brush(knock=2, kind=int(self.muse_knock_double))


def _update_muse_knock_triple(self, context):
    if not hasattr(bpy.ops.wm, "ios_immersive_set_muse_knock_brush"):
        return
    bpy.ops.wm.ios_immersive_set_muse_knock_brush(knock=3, kind=int(self.muse_knock_triple))


class ImmersiveOptions(PropertyGroup):
    use_hand_as_pen: BoolProperty(
        name="手をペン代わりに",
        description="Immersive で右手の人差し指＋ピンチを Muse の代わりに使う",
        default=False,
        update=_update_hand_as_pen,
    )
    hand_proximity_sculpt: BoolProperty(
        name="手の近接でスカルプト",
        description="Hand入力時、ピンチ不要。ブラシ半径内の頂点に近づいたときだけスカルプトする",
        default=False,
        update=_update_hand_proximity_sculpt,
    )
    use_dyntopo: BoolProperty(
        name="Dyntopo",
        description="Dynamic Topology（デフォルト ON）",
        default=True,
        update=_update_dyntopo,
    )
    strength: FloatProperty(
        name="Strength",
        default=0.5,
        min=0.05,
        max=1.0,
        subtype='FACTOR',
        update=_update_strength,
    )
    radius: FloatProperty(
        name="Radius",
        description="ブラシ半径（メートル）",
        default=0.25,
        min=0.02,
        max=0.80,
        unit='LENGTH',
        update=_update_radius,
    )
    mode: EnumProperty(
        name="Mode",
        items=(
            ('0', "Object", "Object Mode（Immersive は閲覧専用）"),
            ('1', "Edit", "Edit Mode"),
            ('2', "Sculpt", "Sculpt Mode"),
            ('3', "VPaint", "Vertex Paint"),
            ('4', "Anim", "Pose / Animation（ボーン掴み）"),
        ),
        default='2',
        update=_update_mode,
    )
    sync_transforms_to_space: BoolProperty(
        name="物体移動も空間へ反映（軽量）",
        description=(
            "複数オブジェクトの位置移動を Immersive に送る（軽量：USDなし / 位置のみ、"
            "拡大縮小・回転は反映されません）。"
            "テトリス等のデモ向け。形状・構成の変更は引き続き USD 再出力で反映されます"
        ),
        default=False,
        update=_update_sync_transforms,
    )
    usd_refresh_interval: FloatProperty(
        name="空間更新間隔",
        description=(
            "Immersive への USD 再出力の間隔（秒）。"
            "短い=サクサクだが重い / 長い=軽い。デフォルト 0.35"
        ),
        default=0.35,
        min=0.08,
        max=2.0,
        soft_min=0.1,
        soft_max=1.0,
        precision=2,
        update=_update_usd_refresh_interval,
    )
    muse_knock_single: EnumProperty(
        name="シングルノック",
        description="Muse 選択ボタンを1回ノックしたときのブラシ",
        items=_MUSE_BRUSH_ITEMS,
        default='4',
        update=_update_muse_knock_single,
    )
    muse_knock_double: EnumProperty(
        name="ダブルノック",
        description="Muse 選択ボタンを2回ノックしたときのブラシ",
        items=_MUSE_BRUSH_ITEMS,
        default='5',
        update=_update_muse_knock_double,
    )
    muse_knock_triple: EnumProperty(
        name="トリプルノック",
        description="Muse 選択ボタンを3回ノックしたときのブラシ",
        items=_MUSE_BRUSH_ITEMS,
        default='6',
        update=_update_muse_knock_triple,
    )


class ImmersivePanelBase:
    bl_region_type = 'UI'
    bl_category = "Immersive"

    @classmethod
    def poll(cls, context):
        return _has_immersive_ops()

    def draw(self, context):
        layout = self.layout
        opts = context.window_manager.immersive_options

        col = layout.column(align=True)
        col.label(text="Vision Pro Immersive", icon='WORLD')
        col.operator("wm.ios_immersive_toggle", text="Immersive 開く / 閉じる", icon='PLAY')
        if hasattr(bpy.ops.wm, "ios_immersive_extract_active"):
            col.operator(
                "wm.ios_immersive_extract_active",
                text="ビューから取り出して編集",
                icon='OUTLINER_OB_MESH',
            )
            hint = col.column(align=True)
            hint.scale_y = 0.85
            hint.label(text="アクティブ物体を手へ→離してスカルプト")

        box = layout.box()
        box.label(text="入力", icon='HAND')
        box.prop(opts, "use_hand_as_pen")
        if opts.use_hand_as_pen:
            box.prop(opts, "hand_proximity_sculpt")
        help_col = box.column(align=True)
        help_col.scale_y = 0.85
        help_col.label(text="ON: 右手の甲=ブラシ位置")
        help_col.label(text="発火: ピンチ / 近接 を切替")
        help_col.label(text="OFF: Logitech Muse")

        box = layout.box()
        box.label(text="空間シーン同期", icon='FILE_REFRESH')
        box.prop(opts, "sync_transforms_to_space")
        box.prop(opts, "usd_refresh_interval", slider=True)
        hint = box.column(align=True)
        hint.scale_y = 0.85
        hint.label(text="短い=速いが重い / 長い=軽い")
        hint.label(text="デモ時は「物体移動も…」をON")

        box = layout.box()
        box.label(text="スカルプト", icon='SCULPTMODE_HLT')
        box.prop(opts, "mode", text="")
        if opts.mode == '0':
            note = box.column(align=True)
            note.scale_y = 0.85
            note.label(text="Object = Immersive 閲覧専用")
            note.label(text="取り出し後は自動で Sculpt")
        box.prop(opts, "use_dyntopo")
        box.prop(opts, "strength", slider=True)
        box.prop(opts, "radius", slider=True)
        if hasattr(bpy.ops.wm, "ios_immersive_remesh"):
            box.operator("wm.ios_immersive_remesh", text="リメッシュ", icon='MOD_REMESH')

        if opts.mode == '2':
            knock = layout.box()
            knock.label(text="Muse ノック（選択ボタン）", icon='MOUSE_LMB')
            knock.prop(opts, "muse_knock_single", text="シングル")
            knock.prop(opts, "muse_knock_double", text="ダブル")
            knock.prop(opts, "muse_knock_triple", text="トリプル")
            hint = knock.column(align=True)
            hint.scale_y = 0.85
            hint.label(text="筆圧ボタン以外を連続ノック")
            hint.label(text="判定窓 0.35秒 / 既定: +/−/Mask")


class VIEW3D_PT_immersive(ImmersivePanelBase, Panel):
    bl_space_type = 'VIEW_3D'
    bl_label = "Immersive"
    bl_idname = "VIEW3D_PT_immersive"


class IMAGE_PT_immersive(ImmersivePanelBase, Panel):
    bl_space_type = 'IMAGE_EDITOR'
    bl_label = "Immersive"
    bl_idname = "IMAGE_PT_immersive"


classes = (
    ImmersiveOptions,
    VIEW3D_PT_immersive,
    IMAGE_PT_immersive,
)


def register_props():
    bpy.types.WindowManager.immersive_options = bpy.props.PointerProperty(type=ImmersiveOptions)


def unregister_props():
    if hasattr(bpy.types.WindowManager, "immersive_options"):
        del bpy.types.WindowManager.immersive_options
