provider "aws" {
  region  = "ap-south-1"
  profile = "roy"
}

# create key pair
resource "tls_private_key" "amazon_linux_key_private" {
  algorithm   = "RSA"
  rsa_bits = 2048
}

resource "aws_key_pair" "amazon_linux_key" {

depends_on = [
    tls_private_key.amazon_linux_key_private,
  ]

  key_name   = "amazon_linux_key"
  public_key = tls_private_key.amazon_linux_key_private.public_key_openssh
}

# create a secuity group

resource "aws_security_group" "allow_http_ssh" {
  name        = "allow_http_ssh"
  vpc_id      = "vpc-6c938e04"
  description = "Allow all http and ssh"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_http_ssh"
  }
}

# launch aws ec2 instance

resource "aws_instance" "amazon_linux_os" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"

  key_name = "amazon_linux_key"

  security_groups = [ "${aws_security_group.allow_http_ssh.name}" ]

  tags = {
    Name = "amazon_linux_os"
  }
}

# connect ec2 instance

resource "null_resource" "connection_after_instance_launch"  {

    depends_on = [
        aws_instance.amazon_linux_os,
    ]

    connection {
        type        = "ssh"
        user        = "ec2-user"
        private_key = tls_private_key.amazon_linux_key_private.private_key_pem
        host        = aws_instance.amazon_linux_os.public_ip
    }

    provisioner "remote-exec" {
        inline = [
            "sudo yum install httpd  php git -y",
            "sudo systemctl start httpd",
            "sudo systemctl enable httpd",
        ] 
    }
}


# Create Ebs volume

resource "aws_ebs_volume" "ebs_amazon_linux_os" {

depends_on = [
    aws_instance.amazon_linux_os, null_resource.connection_after_instance_launch,
  ]

  availability_zone = aws_instance.amazon_linux_os.availability_zone
  size              = 1

  tags = {
    Name = "pd_amazon_linux_os_server"
  }
}


# attach ebs volume to instance

resource "aws_volume_attachment" "ebs_amazon_linux_os_attach" {

depends_on = [
    aws_instance.amazon_linux_os, aws_ebs_volume.ebs_amazon_linux_os,
  ]

  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ebs_amazon_linux_os.id
  instance_id = aws_instance.amazon_linux_os.id
  force_detach = true

}

# Create S3 bucket

resource "aws_s3_bucket" "amazon_linux_os_bucket" {

depends_on = [
    aws_volume_attachment.ebs_amazon_linux_os_attach,
  ]

  bucket = "amazon-linux-os-bucket"
  acl    = "public-read"
  force_destroy = true
  tags = {
    Name = "amazon_linux_os_s3_bucket"
  }
}

   locals {
    s3_origin_id = "myorigin"
}

resource "aws_s3_bucket_public_access_block" "make_item_public" {
  bucket = aws_s3_bucket.amazon_linux_os_bucket.id

  block_public_acls   = false
  block_public_policy = false
}

# index.html in s3

resource "aws_s3_bucket_object" "amazon_linux_os_bucket_object" {

depends_on = [
    aws_s3_bucket.amazon_linux_os_bucket,
  ]

  bucket = aws_s3_bucket.amazon_linux_os_bucket.id
  key    = "index.html"
  source = "index.html"

  acl    = "public-read"
}

# Create cloudFront distrubution

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "origin access identity"
}

resource "aws_cloudfront_distribution" "amazon_linux_os_cloudfront" {

  depends_on = [
      aws_s3_bucket_object.amazon_linux_os_bucket_object,
  ]

  origin {
    domain_name = aws_s3_bucket.amazon_linux_os_bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
        origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

    enabled             = true
    is_ipv6_enabled     = true
      comment             = "my cloudfront s3 distribution"
      default_root_object = "index.php"

  default_cache_behavior {

    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]

    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

   viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

   restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true  
  }
}

# Connect to ec2 instance

resource "null_resource" "connection"  {

 depends_on = [
    aws_s3_bucket_object.amazon_linux_os_bucket_object,aws_cloudfront_origin_access_identity.origin_access_identity,
        aws_cloudfront_distribution.amazon_linux_os_cloudfront,
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"

    private_key = tls_private_key.amazon_linux_key_private.private_key_pem

    host     = aws_instance.amazon_linux_os.public_ip
  }

provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdh",
      "sudo mount  /dev/xvdh  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/Shashikant17/cloudfront.git /var/www/html/",
      "sudo su << EOF",
            "echo \"${aws_cloudfront_distribution.amazon_linux_os_cloudfront.domain_name}\" >> /var/www/html/myimg.txt",
            "EOF",
      "sudo systemctl stop httpd",
      "sudo systemctl start httpd",
      "sudo systemctl enable httpd"
    ]
  }
}

# launch web browser

resource "null_resource" "chrome_output"  {

depends_on = [
    aws_cloudfront_distribution.amazon_linux_os_cloudfront,null_resource.connection,
  ]

    provisioner "local-exec" {
        command = "start chrome  ${aws_instance.amazon_linux_os.public_ip}"
    }

}
