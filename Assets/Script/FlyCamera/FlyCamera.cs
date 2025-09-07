using UnityEngine;

public class FlyCamera : MonoBehaviour
{
    public float movementSpeed = 10f;
    public float lookSpeed = 2f;
    public float sprintMultiplier = 2f;

    float yaw = 0f;
    float pitch = 0f;

    void Start()
    {
        Vector3 angles = transform.eulerAngles;
        yaw = angles.y;
        pitch = angles.x;
        Cursor.lockState = CursorLockMode.Locked;
        Cursor.visible = false;
    }

    void Update()
    {
        // Lock fly camera controls when P is held
        if (Input.GetKey(KeyCode.P))
        {
            Cursor.visible = false; // ensure cursor stays hidden
            return;
        }

        Cursor.visible = false; // always hide cursor during fly camera

        // Mouse look
        float mouseX = Input.GetAxis("Mouse X") * lookSpeed;
        float mouseY = Input.GetAxis("Mouse Y") * lookSpeed;

        yaw += mouseX;
        pitch -= mouseY;
        pitch = Mathf.Clamp(pitch, -89f, 89f);

        transform.eulerAngles = new Vector3(pitch, yaw, 0f);

        // Movement
        float speed = movementSpeed;
        if (Input.GetKey(KeyCode.LeftShift))
            speed *= sprintMultiplier;

        Vector3 move = new Vector3(
            Input.GetAxis("Horizontal"),
            0,
            Input.GetAxis("Vertical")
        );
        move = transform.TransformDirection(move);
        transform.position += move * speed * Time.deltaTime;
    }
}
