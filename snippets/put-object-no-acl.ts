// snippets/put-object-no-acl.ts
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

export const s3 = new S3Client({
  region: process.env.AWS_REGION,
  endpoint: process.env.AWS_S3_UPLOAD_BUCKET_URL,
  forcePathStyle: process.env.AWS_S3_FORCE_PATH_STYLE === "true",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID as string,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY as string,
  },
});

export async function putObjectNoAcl(params: {
  bucket: string;
  key: string;
  body: Buffer | Uint8Array | Blob | string;
  contentType?: string;
}) {
  const { bucket, key, body, contentType } = params;

  const cmd = new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    Body: body,
    ...(contentType ? { ContentType: contentType } : {}),
    // IMPORTANT: No ACL parameter here
  });

  return s3.send(cmd);
}
