using UdonSharpEditor;
using UnityEditor;
using UnityEngine;
using VRC.SDK3.Components;

namespace MatrixCocoa.EditorTools
{
    internal static class BroomBuilder
    {
        private const string Art = "Assets/MatrixCocoa/Broom/";

        internal static GameObject Build(Transform root, Transform spawn)
        {
            // Start within interaction range to the right of spawn, pointing into the city.
            var broom = new GameObject("Flying Broom") { layer = LayerMask.NameToLayer("Pickup") };
            broom.transform.SetParent(root, false);
            broom.transform.SetPositionAndRotation(spawn.TransformPoint(new Vector3(0.9f, 0.65f, 1.8f)), spawn.rotation);
            AddMesh(broom.transform, "BroomHandle", "Standard", new Color(0.28f, 0.15f, 0.075f));
            AddMesh(broom.transform, "BroomBristles", "Sprites/Default", Color.white);

            var hitbox = broom.AddComponent<CapsuleCollider>();
            hitbox.direction = 2;
            hitbox.radius = 0.15f;
            hitbox.height = 1.9f;
            hitbox.isTrigger = true;
            var body = broom.AddComponent<Rigidbody>();
            body.isKinematic = true;
            body.useGravity = false;
            var sync = broom.AddComponent<VRCObjectSync>();
            var station = broom.AddComponent<VRCStation>();
            station.PlayerMobility = VRCStation.Mobility.ImmobilizeForVehicle;
            station.seated = true;
            station.canUseStationFromStation = false;
            station.disableStationExit = true;
            station.stationEnterPlayerLocation = Point(broom.transform, "Pilot", Vector3.down * 0.45f);
            station.stationExitPlayerLocation = Point(broom.transform, "Dismount", new Vector3(0.7f, -0.45f, 0f));

            var ride = UdonSharpUndo.AddComponent<BroomRide>(broom);
            ride.station = station;
            ride.sync = sync;
            ride.exitPoint = station.stationExitPlayerLocation;
            UdonSharpEditorUtility.CopyProxyToUdon(ride);
            var udon = UdonSharpEditorUtility.GetBackingUdonBehaviour(ride);
            udon.interactText = "Ride the broom";
            udon.proximity = 2.5f;
            EditorUtility.SetDirty(udon);
            return broom;
        }

        private static void AddMesh(Transform parent, string name, string shader, Color color)
        {
            var path = Art + name;
            var mesh = AssetDatabase.LoadAssetAtPath<Mesh>(path + ".asset");
            var mat = AssetDatabase.LoadAssetAtPath<Material>(path + ".mat");
            if (mat == null)
            {
                mat = new Material(Shader.Find(shader)) { color = color };
                AssetDatabase.CreateAsset(mat, path + ".mat");
            }
            var part = Point(parent, name, Vector3.zero).gameObject;
            part.AddComponent<MeshFilter>().sharedMesh = mesh;
            part.AddComponent<MeshRenderer>().sharedMaterial = mat;
        }

        private static Transform Point(Transform parent, string name, Vector3 localPosition)
        {
            var point = new GameObject(name).transform;
            point.SetParent(parent, false);
            point.localPosition = localPosition;
            return point;
        }
    }
}
