"""Reanchor saved scatter transforms without changing their local size or rotation."""

import re
import numpy as np


def edit_multimesh_scene(text, name_prefix, resource_prefix, edit):
    """Call edit for each stand; return text and final root counts in resource order."""
    node_pattern=rf'\[node name="({name_prefix}_[^"]+)"[^\n]*\n([\s\S]*?)(?=\n\[node|\Z)'
    resource_pattern=rf'\[sub_resource type="MultiMesh" id="{resource_prefix}_(\d+)"\]([\s\S]*?)(?=\n\[sub_resource|\n\[node|\Z)'
    positions={}
    for match in re.finditer(node_pattern,text):
        body=match.group(2)
        resource=re.search(rf'multimesh = SubResource\("{resource_prefix}_(\d+)"\)',body)
        position=re.search(r'position = Vector3\(([^)]+)\)',body)
        if resource and position:
            positions[int(resource.group(1))]=(match.group(1),np.fromstring(position.group(1),sep=","))
    edited_positions={}
    empty_nodes=set()
    counts=[]

    def replace_resource(match):
        rid=int(match.group(1))
        name,position=positions[rid]
        body=match.group(2)
        found=re.search(r'buffer = PackedFloat32Array\(([^)]*)\)',body)
        rows=np.fromstring(found.group(1),sep=",").reshape(-1,16)
        rows,new_position=edit(rows,position)
        if not len(rows):
            empty_nodes.add(name)
            return ""
        if new_position is not None:
            edited_positions[name]=new_position
        counts.append(len(rows))
        body=re.sub(r'instance_count = \d+',f'instance_count = {len(rows)}',body)
        body=body[:body.index('buffer = PackedFloat32Array(')]+"buffer = PackedFloat32Array("+", ".join(f"{v:.4f}" for v in rows.ravel())+")\n"
        return f'[sub_resource type="MultiMesh" id="{resource_prefix}_{rid}"]'+body

    def replace_position(match):
        name,body=match.groups()
        if name in empty_nodes:
            return ""
        if name in edited_positions:
            position="Vector3("+", ".join(f"{v:.4f}" for v in edited_positions[name])+")"
            body=re.sub(r'position = Vector3\([^)]+\)',"position = "+position,body)
        return match.group(0).split("\n",1)[0]+"\n"+body

    text=re.sub(resource_pattern,replace_resource,text)
    text=re.sub(node_pattern,replace_position,text)
    child_pattern=r'\[node[^\n]* parent="([^"]+)"[^\n]*\n[\s\S]*?(?=\n\[node|\Z)'
    text=re.sub(child_pattern,lambda m:"" if m.group(1) in empty_nodes else m.group(0),text)
    return text,counts
