using UdonSharp;
using UnityEngine;
using VRC.SDK3.Components;
using VRC.SDKBase;
using VRC.Udon.Common;
using VRCStation = VRC.SDK3.Components.VRCStation;

namespace MatrixCocoa
{
    // Flight controls adapted from Unearthed's Rideable. City geometry replaces its dune height field.
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class BroomRide : UdonSharpBehaviour
    {
        public VRCStation station;
        public VRCObjectSync sync;
        public Transform exitPoint;

        private const float Speed = 20f;
        private const float Accel = 2.6f;
        private const float NitroBoost = 3f;
        private const float NitroTime = 2.5f;
        private const float NitroCooldown = 5f;
        private const float TurnRate = 100f;
        private const float MaxBank = 30f;
        private const float PitchFollow = 0.6f;
        private const float WorldRadius = 2400f; // within the city's collidable range
        private const int CityMask = 1; // generated buildings and spawn platform are on Default

        private bool pilotIn, riding;
        private float fwdIn, sideIn, lookIn;
        private float nitroLeft, cooldownLeft;
        private float yaw, roll, visPitch, idle;
        private Vector3 pos, vel, exitVel, home;

        private void Start()
        {
            home = transform.position;
            SendCustomEventDelayedSeconds(nameof(Tick), 5f);
        }

        public override void Interact()
        {
            if (!pilotIn) station.UseStation(Networking.LocalPlayer);
        }

        public override void OnStationEntered(VRCPlayerApi player)
        {
            pilotIn = true;
            DisableInteractive = true;
            idle = 0f;
            if (!Utilities.IsValid(player) || !player.isLocal) return;
            Networking.SetOwner(player, gameObject);
            yaw = transform.eulerAngles.y;
            roll = 0f; visPitch = 0f; vel = Vector3.zero;
            fwdIn = 0f; sideIn = 0f; lookIn = 0f; nitroLeft = 0f;
            pos = transform.position;
            MoveInCity(pos + Vector3.up * 0.6f);
            transform.SetPositionAndRotation(pos, Quaternion.Euler(0f, yaw, 0f));
            riding = true;
            UpdateExit();
        }

        public override void OnStationExited(VRCPlayerApi player)
        {
            pilotIn = false;
            DisableInteractive = false;
            if (!Utilities.IsValid(player) || !player.isLocal || !riding) return;
            riding = false;
            transform.SetPositionAndRotation(pos, Quaternion.Euler(0f, yaw, 0f));
            exitVel = vel;
            SendCustomEventDelayedSeconds(nameof(PushOff), 0.12f);
        }

        public void PushOff()
        {
            if (riding) return;
            VRCPlayerApi lp = Networking.LocalPlayer;
            if (!Utilities.IsValid(lp)) return;
            // VRChat can leave the player grounded after exiting a station in midair.
            Vector3 v = exitVel * 0.5f;
            v.y = 0f;
            v = Vector3.ClampMagnitude(v, 6f);
            v.y = Mathf.Min(exitVel.y * 0.5f, 0f) - 1.5f;
            lp.SetVelocity(v);
        }

        public void Tick()
        {
            SendCustomEventDelayedSeconds(nameof(Tick), 5f);
            if (pilotIn || !Networking.IsOwner(gameObject)) { idle = 0f; return; }
            if ((transform.position - home).sqrMagnitude < 0.01f) { idle = 0f; return; }
            idle += 5f;
            if (idle < 30f) return;
            idle = 0f;
            cooldownLeft = 0f;
            sync.Respawn();
        }

        public override void InputJump(bool value, UdonInputEventArgs args)
        {
            if (riding && value) station.ExitStation(Networking.LocalPlayer);
        }

        public override void InputMoveVertical(float value, UdonInputEventArgs args) { fwdIn = value; }
        public override void InputMoveHorizontal(float value, UdonInputEventArgs args) { sideIn = value; }
        public override void InputLookHorizontal(float value, UdonInputEventArgs args) { lookIn = value; }
        public override void InputUse(bool value, UdonInputEventArgs args)
        {
            if (riding && value && nitroLeft <= 0f && cooldownLeft <= 0f) nitroLeft = NitroTime;
        }

        private void Update()
        {
            if (!riding) return;
            VRCPlayerApi lp = Networking.LocalPlayer;
            if (!Utilities.IsValid(lp)) return;
            float dt = Time.deltaTime;

            // Steer towards the gaze (with a dead zone), plus the right stick.
            Quaternion head = lp.GetTrackingData(VRCPlayerApi.TrackingDataType.Head).rotation;
            Vector3 hf = Quaternion.Inverse(Quaternion.Euler(0f, yaw, 0f)) * (head * Vector3.forward);
            float offYaw = Mathf.Atan2(hf.x, hf.z) * Mathf.Rad2Deg;
            float lookPitch = -Mathf.Asin(Mathf.Clamp(hf.y, -1f, 1f)) * Mathf.Rad2Deg;
            float off = Mathf.Abs(offYaw) > 10f ? offYaw - Mathf.Sign(offYaw) * 10f : 0f;
            float steer = Mathf.Clamp(off / 45f, -1f, 1f);
            if (Mathf.Abs(lookIn) > 0.15f) steer = Mathf.Clamp(steer + lookIn, -1.5f, 1.5f);
            yaw += steer * TurnRate * dt;

            bool nitro = nitroLeft > 0f;
            if (nitro) { nitroLeft -= dt; if (nitroLeft <= 0f) cooldownLeft = NitroCooldown; }
            else if (cooldownLeft > 0f) cooldownLeft -= dt;

            float flyPitch = Mathf.Abs(lookPitch) > 12f ? lookPitch - Mathf.Sign(lookPitch) * 12f : 0f;
            float lim = nitro ? 20f : 60f;
            flyPitch = Mathf.Clamp(flyPitch, -lim, lim);
            float top = Speed * (nitro ? NitroBoost : 1f);
            float thrust = nitro ? Mathf.Max(fwdIn, 1f) : fwdIn;
            Vector3 want = Quaternion.Euler(flyPitch, yaw, 0f) * Vector3.forward * (thrust * top)
                         + Quaternion.Euler(0f, yaw, 0f) * Vector3.right * (sideIn * Speed * 0.6f);
            vel = Vector3.Lerp(vel, want, 1f - Mathf.Exp(-(nitro ? Accel * 2f : Accel) * dt));
            MoveInCity(pos + vel * dt);

            float spd = vel.magnitude;
            float k = 1f - Mathf.Exp(-4f * dt);
            roll = Mathf.Lerp(roll, Mathf.Clamp(-steer * MaxBank - sideIn * MaxBank * 0.7f, -MaxBank * 1.5f, MaxBank * 1.5f), k);
            visPitch = Mathf.Lerp(visPitch, flyPitch * PitchFollow * Mathf.Clamp01(spd / Speed) * Mathf.Sign(fwdIn + 0.001f), k);
            float bob = Mathf.Sin(Time.time * 2.2f) * 0.035f * (1f - Mathf.Clamp01(spd / 3f));
            transform.SetPositionAndRotation(pos + Vector3.up * bob, Quaternion.Euler(visPitch, yaw, roll));
            UpdateExit();
        }

        private void MoveInCity(Vector3 target)
        {
            float r = Mathf.Sqrt(target.x * target.x + target.z * target.z);
            if (r > WorldRadius)
            {
                Vector3 n = new Vector3(target.x / r, 0f, target.z / r);
                target -= n * (r - WorldRadius);
                float outward = Vector3.Dot(vel, n);
                if (outward > 0f) vel -= n * outward;
            }
            float y = Mathf.Clamp(target.y, -1400f, 1000f);
            if (target.y != y && Mathf.Sign(vel.y) == Mathf.Sign(target.y - y)) vel.y = 0f;
            target.y = y;

            Vector3 delta = target - pos;
            float distance = delta.magnitude;
            if (distance < 0.0001f) return;
            Vector3 dir = delta / distance;
            // Sweep the seated rider through roofs and walls, including at full nitro speed.
            RaycastHit hit;
            if (Physics.CapsuleCast(pos, pos + Vector3.up * 0.8f, 0.42f, dir, out hit, distance + 0.05f, CityMask, QueryTriggerInteraction.Ignore))
            {
                distance = Mathf.Clamp(hit.distance - 0.05f, 0f, distance);
                float into = Vector3.Dot(vel, hit.normal);
                if (into < 0f) vel -= hit.normal * into;
            }
            pos += dir * distance;
        }

        private void UpdateExit()
        {
            Quaternion level = Quaternion.Euler(0f, yaw, 0f);
            Vector3 side = level * Vector3.right;
            Vector3 center = transform.position;
            RaycastHit hit;
            if (Physics.SphereCast(center, 0.2f, side, out hit, 0.9f, CityMask, QueryTriggerInteraction.Ignore)) side = -side;
            exitPoint.SetPositionAndRotation(center + side * 0.7f - Vector3.up * 0.45f, level);
        }
    }
}
