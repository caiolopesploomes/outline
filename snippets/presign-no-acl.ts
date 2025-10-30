// snippets/presign-no-acl.ts
import { S3Client } from "@aws-sdk/client-s3";
import { createPresignedPost } from "@aws-sdk/s3-presigned-post";

export const s3 = new S3Client({
  region: process.env.AWS_REGION,
  endpoint: process.env.AWS_S3_UPLOAD_BUCKET_URL, // works for S3-compatible
  forcePathStyle: process.env.AWS_S3_FORCE_PATH_STYLE === "true",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID as string,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY as string,
  },
});

export async function presignUploadNoAcl(params: {
  bucket: string;
  key: string;
  contentType?: string;
  maxSizeBytes?: number;
}) {
  const { bucket, key, contentType, maxSizeBytes = 50 * 1024 * 1024 } = params;

  const { url, fields } = await createPresignedPost(s3, {
    Bucket: bucket,
    Key: key,
    // IMPORTANT: No ACL in Conditions and Fields for OCI
    Conditions: [["content-length-range", 1, maxSizeBytes]],
    Fields: {
      ...(contentType ? { "Content-Type": contentType } : {}),
    },
    Expires: 3600,
  });

  return { url, fields };
}
