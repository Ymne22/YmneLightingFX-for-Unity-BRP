using UnityEngine;

public class Rotator : MonoBehaviour
{
    public Vector3 rotationDirection = Vector3.up;
    public float rotationSpeed = 90f; // degrees per second
    public bool rotateGlobal = false;

    void Update()
    {
        if (rotateGlobal)
            transform.Rotate(rotationDirection.normalized * rotationSpeed * Time.deltaTime, Space.World);
        else
            transform.Rotate(rotationDirection.normalized * rotationSpeed * Time.deltaTime, Space.Self);
    }
}
